# CI session serialization check

The aim is to find session serialization problems in the Jenkins build, well
before HA and load testing in UAT. Serialization failures are the most common
cause of broken session replication and passivation. The plan:

1. Create a branch of the application.
2. Turn on `javax.faces.SERIALIZE_SERVER_STATE=true` and add a test-only
   session serialization filter.
3. Run the existing Selenium UI tests in the Jenkins job for that branch. The
   job starts JBoss, the database, the DataGrid etc. with `docker compose up`.
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
attributes separately in the session. Application data held in backing beans
lives there, and the setting won't check it.

This filter runs after each request. For every session attribute it:

1. **writes** it with `ObjectOutputStream` (the same thing replication and
   passivation do), then
2. **reads it back** with `ObjectInputStream` (the same thing activation and
   failover do on the other node).

Any failure is logged once per attribute, step and exception type, with a marker
that is easy to grep for:

```java
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.ObjectInputStream;
import java.io.ObjectOutputStream;
import java.io.ObjectStreamClass;
import java.util.Collections;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;

import javax.servlet.Filter;
import javax.servlet.FilterChain;
import javax.servlet.ServletException;
import javax.servlet.ServletRequest;
import javax.servlet.ServletResponse;
import javax.servlet.annotation.WebFilter;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpSession;

import org.jboss.logging.Logger;

@WebFilter("/*")
public class SessionSerializationCheckFilter implements Filter {
    private static final Logger LOG = Logger.getLogger(SessionSerializationCheckFilter.class);
    private static final Set<String> REPORTED = ConcurrentHashMap.newKeySet();

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
                        check(name, session.getAttribute(name), httpReq.getRequestURI());
                    }
                } catch (IllegalStateException invalidated) {
                    // session was invalidated during the request (e.g. logout)
                }
            }
        }
    }

    private void check(String name, Object value, String uri) {
        byte[] bytes;
        try {
            ByteArrayOutputStream buffer = new ByteArrayOutputStream();
            try (ObjectOutputStream out = new ObjectOutputStream(buffer)) {
                out.writeObject(value);
            }
            bytes = buffer.toByteArray();
        } catch (IOException | RuntimeException e) {
            // RuntimeException: e.g. Hibernate LazyInitializationException from a
            // detached entity in the session - log it, don't fail the request
            report("write", name, uri, e);
            return;
        }
        try (ObjectInputStream in = new DeploymentObjectInputStream(new ByteArrayInputStream(bytes))) {
            in.readObject();
        } catch (IOException | ClassNotFoundException | RuntimeException e) {
            // e.g. InvalidObjectException caused by Weld UnproxyableResolutionException,
            // InvalidClassException, or a readObject()/readResolve() that fails
            report("read", name, uri, e);
        }
    }

    private void report(String step, String name, String uri, Exception e) {
        if (REPORTED.add(step + "|" + name + "|" + e.getClass().getName())) {
            LOG.warnf(e, "SESSION-SERIALIZATION-FAILURE step=%s attribute=%s uri=%s: %s",
                    step, name, uri, e);
        }
    }

    /** Resolves classes with the deployment's class loader, as the session manager does. */
    private static final class DeploymentObjectInputStream extends ObjectInputStream {
        DeploymentObjectInputStream(InputStream in) throws IOException {
            super(in);
        }

        @Override
        protected Class<?> resolveClass(ObjectStreamClass desc) throws IOException, ClassNotFoundException {
            try {
                return Class.forName(desc.getName(), false, Thread.currentThread().getContextClassLoader());
            } catch (ClassNotFoundException e) {
                return super.resolveClass(desc);
            }
        }
    }
}
```

- Weld stores CDI session-scoped and view-scoped beans as session attributes,
  so the filter covers them.
- Failures are reported **once** per step, attribute and exception type until
  the server restarts, to keep the log readable. Restart JBoss before each test
  run to get a fresh list. The `uri=` is the first page where each problem
  appeared.
- Writing and reading every attribute on every request costs CPU and memory, so
  keep the filter on the test branch only.
- **`step=write` failures** are problems replication and passivation would hit.
  For example, a Hibernate
  `LazyInitializationException ... could not initialize proxy - no Session`
  means a JPA entity with an uninitialized lazy association is held in the
  session. Replication and passivation walk the same object graph, and the
  entity is detached on the other node anyway. Store IDs or DTOs instead, or
  fetch the needed associations before keeping the entity.
- **`step=read` failures** are problems activation and failover would hit. For
  example, `InvalidObjectException` caused by Weld's
  `UnproxyableResolutionException`: Weld resolves CDI proxies again when they
  are read back and fails if the bean class can't be proxied. The Weld
  message (`WELD-00xxxx`) names the class and the reason: typically no
  non-private no-argument constructor, a `final` class or public method, or a
  normal-scoped producer returning a final type.
- The read-back only proves the objects can be deserialized. It does **not**
  catch `transient` fields that come back `null` and are never rebuilt, or JSF
  views that can't be restored because component IDs changed. Those still need
  the passivation test in section 6.

## 3. Get the exact field that failed

Add this to the JBoss `JAVA_OPTS` in the compose file:

```
-Dsun.io.serialization.extendedDebugInfo=true
```

A plain `NotSerializableException` only names the class. With this flag, the
message includes the whole path to the field, e.g.
`CustomerViewBean.client -> RestClientImpl.connection`, which makes each failure
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
            grep -E 'NotSerializableException|InvalidClassException|InvalidObjectException|WriteAbortedException|LazyInitializationException|UnproxyableResolutionException|SESSION-SERIALIZATION-FAILURE' \
                 server.log* jboss-console.log > serialization-errors.txt || true
            echo "Distinct failures:"
            grep -oE 'NotSerializableException: [^ ]+|SESSION-SERIALIZATION-FAILURE step=[^ ]+ attribute=[^ ]+' \
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

**It proves** that the pages the Selenium tests visit only put objects in the
view state and the session that can be written and read back. CI is the
cheapest place to find these problems.

**It doesn't cover:**

- Pages the Selenium tests never visit, so check how complete the test
  coverage is.
- Correct restore on another node. Component-tree/ID mismatches after a
  postback, DataGrid cache behaviour after failover, and load balancer
  failover still need testing in UAT, because the compose setup runs a single
  JBoss. The compose file could later run two JBoss nodes behind a load
  balancer, the way this demo project does.
- `transient` fields that come back `null` after a restore, and JSF views that
  can't be restored because component IDs changed.

### Single-node passivation test (covers the last point)

This forces one JBoss to passivate a session and restore it, with no second
node needed:

1. Check `web.xml` has `<distributable/>`. Without it, `max-active-sessions`
   doesn't passivate: a new login fails or the older session is discarded.
2. Set `<max-active-sessions>1</max-active-sessions>` in `jboss-web.xml` (local
   test only).
3. Check the server has a passivation store: `/subsystem=distributable-web:read-resource(recursive=true)`
   should show `infinispan-session-management` using the `web` cache container,
   and `/subsystem=infinispan/cache-container=web:read-resource(recursive=true)`
   should show a `file-store`. EAP 7.4's default configuration has both. If it
   shows `hotrod-session-management` instead, sessions live in the remote Data
   Grid and behave differently.
4. **Browser A:** log in, go to a page with the generated-ID fix or with
   `transient` fields, and part-fill a form.
5. **Browser B:** log in as a **different user** (the same username can trigger
   any duplicate-login handling in the app). Browser A's session is passivated.
   `/deployment=YOUR-APP.war/subsystem=undertow:read-attribute(name=active-sessions)`
   should show 1.
6. **Browser A:** submit the form, sort, open record details. Look for errors,
   `NullPointerException`s, empty data, or being logged out.

## 7. Before merging to main

Don't merge `SERIALIZE_SERVER_STATE` or the filter to main unconditionally,
because both cost performance in production. Make them switchable, e.g.
register the filter only when a system property is set. Keeping them on a
branch is fine for the initial trial.
