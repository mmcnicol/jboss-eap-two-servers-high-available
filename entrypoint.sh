#!/usr/bin/env bash
set -euo pipefail

ROLE="${ROLE:?ROLE must be set to master, node1, or node2}"

wait_for_port() {
  local host=$1 port=$2 tries=90
  until nc -z "$host" "$port" 2>/dev/null; do
    tries=$((tries - 1))
    if [ "$tries" -le 0 ]; then
      echo "Timed out waiting for $host:$port" >&2
      exit 1
    fi
    sleep 2
  done
}

case "$ROLE" in
  master)
    : "${EAP_ADMIN_USER:=admin}"
    : "${EAP_ADMIN_PASSWORD:?EAP_ADMIN_PASSWORD must be set}"
    : "${EAP_SLAVE_USER:=slave}"
    : "${EAP_SLAVE_PASSWORD:?EAP_SLAVE_PASSWORD must be set}"

    # Console login + the identity node1/node2 use to join the domain.
    "$JBOSS_HOME/bin/add-user.sh" -u "$EAP_ADMIN_USER" -p "$EAP_ADMIN_PASSWORD" --silent || true
    "$JBOSS_HOME/bin/add-user.sh" -u "$EAP_SLAVE_USER" -p "$EAP_SLAVE_PASSWORD" --silent || true

    "$JBOSS_HOME/bin/domain.sh" \
      -Djboss.bind.address=0.0.0.0 \
      -Djboss.bind.address.management=0.0.0.0 \
      -Djboss.host.name=master \
      --host-config=host-master.xml &
    DOMAIN_PID=$!

    wait_for_port 127.0.0.1 9990

    # Idempotent: safe to re-run (skips steps already applied) if the container restarts.
    # Deliberately not fatal to the container: if this script has a bad resource
    # address, we want master to stay up so you can `docker exec` in and debug
    # with jboss-cli interactively, rather than the container dying outright.
    if "$JBOSS_HOME/bin/jboss-cli.sh" --connect controller=127.0.0.1:9990 \
      --file=/opt/jboss/cli/configure-domain.cli; then
      touch /tmp/healthy
    else
      echo "WARNING: configure-domain.cli failed -- master will stay up for debugging," >&2
      echo "but node1/node2 will not pass the depends_on healthcheck until it succeeds." >&2
      echo "Debug with: docker exec -it wildfly-master \$JBOSS_HOME/bin/jboss-cli.sh --connect controller=127.0.0.1:9990" >&2
    fi

    wait "$DOMAIN_PID"
    ;;

  node1|node2)
    : "${EAP_SLAVE_USER:=slave}"
    : "${EAP_SLAVE_PASSWORD:?EAP_SLAVE_PASSWORD must be set}"

    exec "$JBOSS_HOME/bin/domain.sh" \
      -Djboss.bind.address=0.0.0.0 \
      -Djboss.bind.address.management=0.0.0.0 \
      -Djboss.host.name="$ROLE" \
      -Djboss.domain.master.address=master \
      -Djboss.domain.master.port=9990 \
      -Djboss.domain.master.username="$EAP_SLAVE_USER" \
      -Djboss.domain.master.password="$EAP_SLAVE_PASSWORD" \
      --host-config=host-slave.xml
    ;;

  *)
    echo "Unknown ROLE: $ROLE (expected master, node1, node2)" >&2
    exit 1
    ;;
esac
