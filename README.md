# WildFly domain-mode HA cluster (local Docker stand-in for JBoss EAP 7.4)

Spins up a 2-node JBoss-EAP-style domain-mode cluster with a mod_cluster
front end, entirely on your laptop via Docker Compose. Built on WildFly
(EAP 7.4's open-source upstream) instead of EAP itself, since it's a public
download with no Red Hat login required. Everything here is standard EAP/
WildFly domain-mode configuration -- the same shape you'd use against real
EAP once you have registry/zip access.

## Topology

```
                 ┌──────────────────────────────┐
 client ───────▶ │ master  (:8080)              │
                 │  - Domain Controller          │
                 │  - lb-server (load-balancer    │
                 │    profile, mod_cluster front) │
                 └───────────────┬───────────────┘
                       mod_cluster (MCMP) registration
              ┌────────────────────┴────────────────────┐
              ▼                                          ▼
   ┌─────────────────────┐                    ┌─────────────────────┐
   │ node1 (:8081 direct) │                    │ node2 (:8082 direct) │
   │  server-one           │◀── JGroups/       │  server-one           │
   │  other-server-group    │   Infinispan     │  other-server-group    │
   │  profile: full-ha       │◀── session repl ─▶│  profile: full-ha       │
   └─────────────────────┘                    └─────────────────────┘
```

- **master**: the Domain Controller, plus one server (`lb-server`) running
  WildFly's built-in `load-balancer` profile. This is the mod_cluster front
  end -- it's what you actually send traffic to, on `:8080`.
- **node1** / **node2**: the two application servers you asked for, each a
  domain "slave" host running one server (`server-one`) on the `full-ha`
  profile (`other-server-group`), which includes Infinispan/JGroups
  clustering and HTTP session replication out of the box.
- All three register with each other over Docker's internal network
  (container names `master`/`node1`/`node2` resolve via Docker DNS) -- no
  external load balancer, VM, or cloud service involved.

## Prerequisites

- Docker Desktop (Windows or Mac) or Docker Engine + Compose v2 (Linux).
  No WSL setup needed -- Docker Desktop handles that internally.
- Outbound internet access during `docker compose build` (downloads WildFly
  from GitHub releases: `github.com/wildfly/wildfly/releases`).

## Setup

1. Copy `.env.example` to `.env` and set real passwords:
   ```
   cp .env.example .env
   ```
   (On Windows, just copy the file in Explorer or `copy .env.example .env`.)

2. Build and start everything:
   ```
   docker compose up --build
   ```
   First boot takes a few minutes: master starts, applies the domain
   configuration (creates the load-balancer server-group/server, disables
   multicast advertising, points the app servers' mod_cluster config at the
   front end), then node1/node2 join the domain and start their servers.
   Watch the logs for `node1`/`node2` reaching `"server-one" ... started`.

3. Stop everything: `Ctrl-C`, then `docker compose down` (add `-v` only if
   you also want to drop the built image layers/volumes).

## Verify it's working

- **App entry point (through the load balancer)**: http://localhost:8080/
- **Domain console** (topology, server status): http://localhost:9990/
  (log in with `admin` / the `EAP_ADMIN_PASSWORD` you set)
- **Direct node access** (bypasses the LB, useful for debugging):
  http://localhost:8081/ (node1), http://localhost:8082/ (node2)
- **Confirm mod_cluster has registered both nodes**: the most reliable check
  is master's own log (`docker compose logs master` or `docker logs
  wildfly-master`) -- registration produces a line per node containing
  `MODCLUSTER000010` (node added) once node1/node2 join and their
  `modcluster` subsystem registers with the front end. You can also check
  the domain console's Runtime > Topology view at http://localhost:9990/ to
  see `lb-server`, and node1/node2's `server-one`, all reporting as started.

## Testing failover / session replication / passivation

This is set up specifically so you can reproduce production HA behavior
locally:

1. Deploy any `.war` with `<distributable/>` in `web.xml` to the app tier:
   ```
   docker exec -it wildfly-master /opt/jboss/wildfly/bin/jboss-cli.sh \
     --connect controller=127.0.0.1:9990 \
     --commands="deploy /path/inside/container/myapp.war --server-groups=other-server-group"
   ```
   (You'll need to `docker cp` the war into the master container first, or
   bind-mount a folder in `docker-compose.yml`.)
2. Hit http://localhost:8081/myapp/ directly on node1, establish a session.
3. Hit http://localhost:8082/myapp/ on node2 with the same session cookie --
   Infinispan session replication means node2 should see the same session.
4. To exercise **failover**: `docker compose stop node1` mid-session, then
   keep hitting http://localhost:8080/myapp/ (through the LB) -- mod_cluster
   should route around the dead node without losing the session.
5. To exercise **passivation** specifically: tune the session cache's
   eviction/idle settings via CLI, e.g.
   ```
   /profile=full-ha/subsystem=distributable-web/infinispan-session-management=default:write-attribute(name=granularity,value=SESSION)
   ```
   and inspect `domain/servers/server-one/data/` inside node1/node2 for
   passivated session state, or watch server logs for passivation/activation
   log lines while idling a session past the timeout.

## Notes / things to double check against your actual environment

- **WildFly version**: defaults to `26.1.3.Final` as the nearest open-source
  equivalent to EAP 7.4. Override via `WILDFLY_VERSION` in `.env` if you want
  a different WildFly release, or swap the Dockerfile's download step for a
  `COPY` of a real EAP zip later once you have Red Hat access -- the rest of
  this setup (host-master.xml/host-slave.xml, `full-ha`/`load-balancer`
  profiles, the CLI script) carries over unchanged to real EAP 7.4.
- **Server-group names**: `other-server-group` (profile `full-ha`) is
  WildFly/EAP's out-of-the-box default for the second server group -- if
  your actual EAP domain.xml has been customized to use different names,
  update `other-server-group`/`full-ha` references in `cli/configure-domain.cli`
  and `entrypoint.sh` accordingly.
- **Line endings**: if you edit `entrypoint.sh` or the `.cli` file on
  Windows, the Dockerfile strips `\r` automatically during build, so CRLF
  saves won't break it.
- No persistent volumes are configured -- `docker compose down` followed by
  `up --build` gives you a fully fresh cluster each time. Add volumes for
  `domain/data` per service if you want deployments/state to survive
  restarts.
# jboss-eap-two-servers-high-available
