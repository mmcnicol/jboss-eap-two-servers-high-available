# CI session serialization check

The aim is to find session serialization problems in the Jenkins build, well
before HA and load testing in UAT. Serialization failures are the most common
cause of broken session replication and passivation. The plan:

1. Create a branch of the application.
2. Turn on `javax.faces.SERIALIZE_SERVER_STATE=true` and add a test-only
   session serialization filter.
3. Run the existing Selenium UI tests in the Jenkins job for that branch. The
   job starts JBoss, SQL Server, DataGrid etc. with `docker compose up`.
4. Add a Jenkins step that greps the JBoss server log for serialization
   failures.

## 1. Enable `javax.faces.SERIALIZE_SERVER_STATE`

Add this to `web.xml` on the branch:

```xml
<context-param>
    <param-name>javax.faces.SERIALIZE_SERVER_STATE</param-name>
    <param-value>true</param-value>
</context-param>
```

- It only has an effect with server-side state saving
  (`javax.faces.STATE_SAVING_METHOD=server`, the default). Check that the app
  doesn't set `client`.
- JSF then serializes the view state on every request, not only when a session
  is replicated or passivated.
- If a view's state can't be serialized, the request fails with a
  `FacesException` wrapping `NotSerializableException`. The error goes to
  `server.log`, and the Selenium test for that page will probably fail as well,
  often showing an error page. When a Selenium test fails on this branch,
  check the log grep results before assuming a UI or test bug.

## 2. Cover session attributes as well (test-only filter)

`SERIALIZE_SERVER_STATE` only covers the **JSF component tree state**. Mojarra
stores CDI `@ViewScoped` beans, `@SessionScoped` beans and other session
attributes separately in the session. Patient data held in backing beans lives
there, and the setting won't check it.

This filter runs after each request. It serializes every session attribute and
logs any failure with a marker that is easy to grep for:

```java
@WebFilter("/*")
public class SessionSerializationCheckFilter implements Filter {
    private static final Logger LOG = Logger.getLogger(SessionSerializationCheckFilter.class);

    @Override
    public void doFilter(ServletRequest req, ServletResponse res, FilterChain chain)
            throws IOException, ServletException {
        try {
            chain.doFilter(req, res);
        } finally {
            HttpServletRequest httpReq = (HttpServletRequest) req;
            HttpSession session = httpReq.getSession(false);
            if (session != null) {
                try {
                    for (String name : Collections.list(session.getAttributeNames())) {
                        try (ObjectOutputStream out = new ObjectOutputStream(OutputStream.nullOutputStream())) {
                            out.writeObject(session.getAttribute(name));
                        } catch (IOException e) {
                            LOG.warnf("SESSION-SERIALIZATION-FAILURE attribute=%s uri=%s: %s",
                                    name, httpReq.getRequestURI(), e);
                        }
                    }
                } catch (IllegalStateException invalidated) {
                    // session was invalidated during the request (e.g. logout)
                }
            }
        }
    }
}
```

- Weld stores CDI session-scoped and view-scoped beans as session attributes,
  so the filter covers them.
- `OutputStream.nullOutputStream()` needs Java 11. On Java 8, use a small
  no-op `OutputStream` instead.
- The filter adds overhead on every request, so keep it on the test branch
  only.

## 3. Get the exact field that failed

Add this to the JBoss `JAVA_OPTS` in the compose file:

```
-Dsun.io.serialization.extendedDebugInfo=true
```

A plain `NotSerializableException` only names the class. With this flag, the
message includes the whole path to the field, e.g.
`PatientViewBean.client -> RestClientImpl.connection`, which makes each failure
much quicker to fix.

## 4. Jenkins grep step

- Run the grep **before** `docker compose down`. If the log isn't on a mounted
  volume, copy it out first with `docker compose cp` or `docker compose logs`.
- Include rotated logs (`server.log*`).
- On the first runs, mark the build **unstable** rather than failed, so the
  full list of problems is visible instead of stopping at the first one. Switch
  to failing the build once the list is clean.

```groovy
stage('Check session serialization') {
    steps {
        sh '''
            docker compose logs --no-color jboss > jboss-console.log || true
            grep -E 'NotSerializableException|InvalidClassException|WriteAbortedException|SESSION-SERIALIZATION-FAILURE' \
                 server.log* jboss-console.log > serialization-errors.txt || true
            echo "Distinct failures:"
            grep -oE 'NotSerializableException: [^ ]+|SESSION-SERIALIZATION-FAILURE attribute=[^ ]+' \
                 serialization-errors.txt | sort | uniq -c || true
        '''
        script {
            if (readFile('serialization-errors.txt').trim()) {
                unstable('Session serialization failures found - see serialization-errors.txt')
            }
        }
    }
    post { always { archiveArtifacts artifacts: 'serialization-errors.txt', allowEmptyArchive: true } }
}
```

Adjust the log paths and the compose service name (`jboss`) to match the job.

## 5. Confirm the check is switched on

On the first run, confirm the setting and the filter are active before trusting
a clean log. One way is to temporarily bind a non-serializable object to a test
page and a session-scoped bean, and check that the grep finds both. Otherwise a
clean result might only mean the check never ran.

## 6. What this does and doesn't prove

**It proves** that the pages the Selenium tests visit only put serializable
objects in the view state and the session. CI is the cheapest place to find
these problems.

**It doesn't cover:**

- Pages the Selenium tests never visit, so check how complete the test
  coverage is.
- Correct restore on another node. Component-tree/ID mismatches after a
  postback, DataGrid cache behaviour after failover, and load balancer
  failover still need testing in UAT, because the compose setup runs a single
  JBoss. The compose file could later run two JBoss nodes behind a load
  balancer, the way this demo project does.

## 7. Before merging to main

Don't merge `SERIALIZE_SERVER_STATE` or the filter to main unconditionally,
because both cost performance in production. Make them switchable, e.g.
register the filter only when a system property is set. Keeping them on a
branch is fine for the initial trial.
