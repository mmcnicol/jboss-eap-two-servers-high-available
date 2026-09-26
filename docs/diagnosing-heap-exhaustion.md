# Diagnosing heap exhaustion in a load test

How to find out why a clustered JBoss EAP / JSF application runs out of heap
(`java.lang.OutOfMemoryError: Java heap space`) during a load test at expected
load, and how to size the heap for HTTP sessions.

See also: [HA session replication test plan](ha-session-replication-test-plan.md),
[Creating lots of user sessions](creating-test-sessions.md), and the polling
scripts [`scripts/poll-sessions.sh`](../scripts/poll-sessions.sh) and
[`scripts/poll-sessions.ps1`](../scripts/poll-sessions.ps1) (Windows).

## Read the heap trend first

Look at heap usage over the run in whatever monitoring you have (an APM tool,
JMX, or the polling script below).

| Pattern | Meaning |
| --- | --- |
| **Steadily rising floor** (the low points after each GC keep climbing), with GCs freeing less and less | Objects are being **kept**: typically sessions piling up, or a cache or map with no size limit |
| Sudden spike from a stable level | One large request, e.g. a big list, export or report |
| Sawtooth that stays level | Normal; the heap is not the problem |

Also establish:

- [ ] The exact error text. `Java heap space` and `GC overhead limit exceeded`
      are about heap size; `Metaspace` and `unable to create native thread`
      have other causes.
- [ ] Whether one or both nodes failed, and in which order. If one node fails
      first, the other takes over its sessions and may fail next: a failover
      chain reaction, which matters for HA sizing.
- [ ] How many nodes were running at the time. Record it for every run.
- [ ] GC time and pause trend before the failure.

## Collect evidence

**Heap dump when the error happens.** Add to the server group's JVM options:

```
-XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=/some/disk/with/space
```

A dump is as large as the heap and contains whatever data the application
holds, so treat it as sensitive.

**GC logs:**

```
-Xlog:gc*:file=/path/gc.log:time,uptime                  # Java 11+
-verbose:gc -Xloggc:/path/gc.log -XX:+PrintGCDetails      # Java 8
```

**Session metrics.** Run the polling script during the test:

```bash
export JBOSS_MGMT_USER=monitor-user JBOSS_MGMT_PASS='...'
scripts/poll-sessions.sh -c dc-host:9990 -d app.war -h node1,node2 -s server-one -i 30 > sessions.csv
```

On Windows, use the PowerShell version (Windows PowerShell 5.1 or PowerShell
7). It prompts for the management user's credentials unless
`JBOSS_MGMT_USER` and `JBOSS_MGMT_PASS` are set:

```powershell
.\scripts\poll-sessions.ps1 -Controller dc-host:9990 -Deployment app.war -Hosts node1,node2 -Server server-one -IntervalSeconds 30 -OutFile sessions.csv
```

If Windows blocks the script because it was downloaded, run
`Unblock-File .\scripts\poll-sessions.ps1` once, or start it with
`powershell -ExecutionPolicy Bypass -File .\scripts\poll-sessions.ps1 ...`.

It records, per node: active sessions, sessions created, expired and rejected
sessions, the highest session count, and heap used and max. The key column is
**`sessions_created`**. Compare it with the number of logins in the same period
on the production system, e.g. from audit logs.

## Analyse the heap dump

Open the dump in Eclipse MAT:

1. Run the **Leak Suspects** report.
2. Open the **dominator tree**, grouped by class, sorted by retained size.
3. Check which of these keep the most memory:

| Class or package | Meaning |
| --- | --- |
| `org.wildfly.clustering.web.*`, `org.infinispan.*` | Session storage: active sessions plus replicated backup copies |
| `com.sun.faces.*` (per-session view maps, `LRUMap`) | JSF view state: up to 15 logical views per session by default |
| The application's session-scoped and view-scoped beans | Application data in sessions, e.g. entities, list results |
| `org.infinispan.client.hotrod.*` | A Hot Rod client near cache growing in the JBoss heap |
| `byte[]` with a large retained size | Often serialized session data or view state; check what holds them |

4. Note the **number of sessions** and the **average retained size per
   session**. Those two numbers drive the sizing below.

## Common causes, most likely first

### 1. The load scripts create a new session on every iteration

This is the most common load-test artifact.

- k6 clears cookies at the end of each iteration by default. If each iteration
  logs in, every iteration creates a new session.
- Nobody logs those sessions out, so each stays in memory until the session
  timeout.
- A rate of 5 iterations a second over 20 minutes leaves **6,000 sessions**.
  Real users log in once and keep one session for hours.
- If the active-session count sits at `max-active-sessions`, JBoss is
  passivating sessions beyond that limit, which adds heavy serialization work
  and memory churn under load.

Fix in the scripts:

- Keep one session per virtual user: `noCookiesReset: true`, and log in only on
  the first iteration or in a per-user setup step.
- Or log out at the end of each iteration.
- Set the **login rate** from production data (logins per hour), separately
  from the request rate.
- k6 browser scripts are real browsers, so apply the same rule to them.

### 2. Replication doubles the session memory

With 2 nodes and 2 copies of each session (the default for a distributed web
cache), **each node holds every session**: its own plus a backup copy of the
other node's. When one node stops, the surviving node becomes the owner of all
of them.

### 3. Sessions are bigger than expected

A session holds session-scoped beans plus JSF view state:

- `com.sun.faces.numberOfLogicalViews` and `numberOfViewsInSession` default to
  15 each, so each session can hold up to 15 page views, and more with AJAX.
  Lowering these (e.g. to 5–10) is often the biggest single saving.
- JPA entities kept in session-scoped beans, e.g. a menu or user profile loaded
  at login. Keep small DTOs instead.
- Domain data held in view beans, instead of keys plus a cache lookup.
- **List results in view-scoped beans.** A list page holding thousands of rows
  stays in the session for every stored view. Test with production-like data
  volumes.
- `javax.faces.PARTIAL_STATE_SAVING` must stay `true` (the default). Full state
  saving makes view state much bigger.

### 4. Something else growing in the heap

- A Hot Rod client near cache, or an embedded cache, with no size limit.
  (Caches in a remote Data Grid cluster live in the Data Grid servers, not in
  the JBoss heap.)
- Application-level maps that are never cleaned up, e.g. a registry of logged-in
  users keyed by username.
- Test-only settings deployed by mistake, e.g. a serialization-check filter or
  `javax.faces.SERIALIZE_SERVER_STATE=true`, which add CPU and memory churn on
  every request.

## Rough sizing

The heap needed per node is about:

**all concurrent sessions (both nodes) × average session size + the
application's baseline memory + 30–50% headroom for GC**

It must still fit when **one node carries everything after a failover**. Measure
the average session size from a heap dump, or from heap used after GC at a known
session count. For example, 1,000 sessions at 2 MB each is 2 GB for sessions
alone, before the baseline and headroom.

## Separate stateless deployments (e.g. microservices)

If REST services run in their own server groups:

- [ ] **Remove `<distributable/>`** from stateless WARs. It adds
      session-replication work they don't need.
- [ ] Check they **don't create HTTP sessions**. A stateless REST service can
      still create one per request by accident, through a security filter, a
      `getSession()` call, or JSF on the classpath. Under load that fills a
      small heap quickly. Run the polling script with `-d` set to the service's
      deployment and its server group's servers, and check `sessions_created`.

## Order for the next run

1. Fix the load scripts' session handling, and set the login rate from
   production data.
2. Add the heap-dump and GC-log options, and run the polling script during the
   test.
3. Run on two nodes, then with one node stopped, recording which is which.
4. Compare `sessions_created` with production logins, and analyse the heap dump
   if the error happens again.
5. Then decide between reducing session size and increasing the heap.
