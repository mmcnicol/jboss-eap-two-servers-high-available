# JBoss EAP HA & Session Replication Test Plan

See also: [CI session serialization check](ci-serialization-check.md).

## Overview and prerequisites

Test session replication and session passivation separately, then together, on
the 2-node EAP 7.4 domain (`full-ha` profile) behind the JBoss mod_cluster load
balancer.

| | Replication (failover) | Passivation |
| --- | --- | --- |
| Trigger | A node stops or is killed | Sessions exceed `max-active-sessions` |
| Where the session goes | The other node's memory (Infinispan `web` cache over JGroups) | The Infinispan cache store (usually files under the server's `data/` directory) |
| When it is serialized | At the end of every request that touches the session | When the session is evicted; it is deserialized on its next use |

Because replication serializes on every request, serialization errors can
appear under load even if no session is ever passivated.

- [ ] `web.xml` has `<distributable/>`. Without it, `max-active-sessions`
      rejects or evicts sessions instead of passivating them, and failover loses
      the session.
- [ ] `max-active-sessions` is set in `jboss-web.xml`: low (10–20) for the
      passivation tests, then a sized value for the load test.
- [ ] Both nodes run exactly the same build, with explicit `serialVersionUID`
      on session-stored classes.
- [ ] Infinispan statistics are enabled (`statistics-enabled=true`) on the
      `web` cache container and cache, so passivation and activation counts
      are visible.
- [ ] Each response shows which node served it (a header, a page footer, or the
      route suffix on `JSESSIONID`, e.g. `.node1`).

## Surface serialization problems early

Make serialization failures show up during ordinary functional testing, not only
at failover.

- [ ] Set the Mojarra context parameter
      `javax.faces.SERIALIZE_SERVER_STATE=true` in UAT, so view state is
      serialized on every request.
- [ ] After every test run, search the server logs for
      `NotSerializableException`, `InvalidClassException`,
      `ClassNotFoundException` during unmarshalling, and ISPN/WFLYCLWEB errors.
      Any hit fails the run.
- [ ] No `binding="#{bean.component}"` points at a `@ViewScoped` or
      session-scoped bean. UIComponents are not safely serializable.
- [ ] Backing-bean fields holding an `EntityManager`, REST/HTTP clients, a
      DataGrid `Cache`/`RemoteCache`, streams or non-serializable third-party
      DTOs are `transient` and reloaded lazily.
- [ ] Loggers are `static`.
- [ ] The same review is done for `@SessionScoped` and `@ConversationScoped`
      beans and `@Stateful` EJBs.

## JSF component tree and generated IDs

With server-side state saving, view state lives in the session and is keyed by
component client IDs. If the other node builds the tree differently, the state
no longer matches. That happens with conditional `c:if`/`ui:include` branches or
dynamically added components with `j_idtNN` IDs. Symptoms are
`ViewExpiredException`, duplicate component ID errors, or form values silently
disappearing.

- [ ] For every view that was fixed or excluded: open it, part-fill a form (or
      page/sort a data table), fail the node, then **submit**. A fresh page
      load after failover is not enough.
- [ ] For views kept out of serialization (stateless/transient views or
      similar), document what users should see after failover.
- [ ] A `ViewExpiredException` handler redirects to a sensible page instead of
      showing a stack trace.
- [ ] Session size is measured, and `com.sun.faces.numberOfLogicalViews` /
      `numberOfViewsInSession` (default 15 each) are reviewed, since they
      multiply the stored view state.

## Patient data in backing beans and the DataGrid

The DataGrid is a remote Red Hat Data Grid cluster, so its cache survives a
JBoss node failover. The risk moves to the Data Grid cluster itself.

| DataGrid mode | What happens after failover | What to test |
| --- | --- | --- |
| Remote (Hot Rod to a separate cluster) | The cache survives | Behaviour when the Data Grid is slow or unavailable |

- [ ] DataGrid mode confirmed: remote Red Hat Data Grid, a separate 2-node HA
      cluster reached over Hot Rod (Red Hat advised against the Infinispan
      embedded in EAP). Use the Remote row above.
- [ ] Data Grid failover tested: stop one Data Grid node under load and confirm
      the Hot Rod client switches to the other with no errors; then stop both
      and confirm the app degrades gracefully (timeouts, fallback to the
      external API) instead of hanging.
- [ ] Backing beans hold keys (e.g. patient ID) and look data up in the
      DataGrid, rather than holding copies of large patient objects that are
      replicated on every request.
- [ ] Cache freshness is defined: whether node 1 and node 2 can show different
      versions of the same patient, and what invalidates an entry.
- [ ] Data protection reviewed. Passivation writes patient data unencrypted to
      disk on the app servers, and JGroups sends it in clear text by default.
      Check the store location, file permissions and cleanup, and whether
      cluster traffic needs `SYM_ENCRYPT`/`ASYM_ENCRYPT` or an isolated network.
- [ ] It is known whether UAT holds real, realistic or anonymised patient data.

## Load balancer (mod_cluster) checks

The load balancer must keep users on one node normally and move them cleanly
when that node goes away.

- [ ] Sticky sessions are on.
- [ ] Sticky-session-force is **off**, otherwise the load balancer returns an
      error instead of failing over.
- [ ] Both nodes show as registered and enabled in the load balancer's runtime
      view before each test.
- [ ] Traffic split is checked before the load test. mod_cluster balances on
      load metrics, so it will not be exactly 50/50.
- [ ] The test plan states that the load balancer itself is a single point of
      failure, and whether that is in scope.

## Failover and passivation test checklist

Run each test with a logged-in user part-way through a workflow first, then
again under load. Result values: Not run / Pass / Fail / Blocked.

| # | Test | How | What to check | Result |
| --- | --- | --- | --- | --- |
| 1 | Graceful stop | Domain CLI `:stop` on node 1's server | Session and form state survive; no errors | Not run |
| 2 | Graceful suspend (drain) | `:suspend` with a timeout | In-flight requests finish; new requests go to node 2 | Not run |
| 3 | Hard crash | `kill -9` on the server JVM | Session survives; record which in-flight requests fail (expected) | Not run |
| 4 | Network partition | Block the JGroups ports, or disconnect the VM's network | Behaviour during the split and after the merge; no stale or overwritten data | Not run |
| 5 | Failback | Restart node 1, wait for state transfer, then stop node 2 | Sessions created while node 1 was down survive | Not run |
| 6 | Passivation | Open more sessions than the limit, then return to the oldest | Data restored exactly; activation count increases | Not run |
| 7 | Passivation + failover | Passivate sessions, then fail the node that owns them | Passivated sessions are available on the surviving node | Not run |
| 8 | Concurrent AJAX | Several AJAX requests in flight on one session during failover | No lock timeouts or lost updates | Not run |
| 9 | Session timeout | Leave a session idle past the timeout, before and after failover | Session expires cleanly on both nodes | Not run |

## Load-test checklist

The key test is a failover during steady-state load, with one node carrying 100%
of the traffic afterwards.

- [ ] Each virtual user has its own cookie jar.
- [ ] Scripts extract and send back `javax.faces.ViewState`, and use the fixed
      component IDs rather than `j_idtNN`.
- [ ] Think times are realistic. Session count depends on users and the session
      timeout, not only requests per second.
- [ ] Heap is sized for one node holding **every** session (each node keeps a
      copy with 2 owners). Rough sizing: concurrent sessions × session size.
      The Data Grid is remote, so its cache is not in the JBoss heap.
- [ ] `max-active-sessions` is set to the sized value, not the low
      passivation-test value.
- [ ] A node is failed during the steady-state phase. Error rate, p95/p99
      latency and recovery time are recorded before, during and after.
- [ ] Monitored during the run:
    - heap and GC
    - Infinispan statistics (passivations, activations, replication time)
    - JGroups thread pools and lock-timeout errors
    - external API call rate
    - Undertow active sessions:
      `/deployment=app.war/subsystem=undertow:read-resource(include-runtime=true)`

## Pass criteria

Agree these targets before testing starts; the numbers are placeholders for the
team to fill in.

| Criterion | Target |
| --- | --- |
| Serialization exceptions in server logs | 0 |
| Sessions lost on graceful stop or suspend | 0 |
| Failed in-flight requests on hard kill | At most X |
| p95 response time with one node down | Below Y ms |
| Recovery time after failover | Within Z seconds |
| Passivated sessions restored intact | 100% |
