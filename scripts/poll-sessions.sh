#!/usr/bin/env bash
# Poll HTTP session counts and JVM heap usage from a JBoss EAP domain during a
# load test, and print one CSV row per host every interval.
#
# Uses the domain controller's HTTP management API, so it needs only curl and jq
# on the machine running it. The management user needs at least the Monitor role.
#
# Usage:
#   export JBOSS_MGMT_USER=admin JBOSS_MGMT_PASS='...'
#   scripts/poll-sessions.sh -c dc-host:9990 -d app.war -h node1,node2 [-s server-one] [-i 30] > sessions.csv
#
# Against this repo's demo cluster (docker compose up), with an app deployed:
#   JBOSS_MGMT_USER=admin JBOSS_MGMT_PASS="$EAP_ADMIN_PASSWORD" \
#     scripts/poll-sessions.sh -c localhost:9990 -d app.war -h node1,node2
#
# Columns:
#   time, host, active_sessions, sessions_created, expired_sessions,
#   rejected_sessions, highest_session_count, heap_used_mb, heap_max_mb
# An empty value means that read failed (e.g. the server was stopped for a
# failover test); polling carries on.

set -euo pipefail

CONTROLLER=localhost:9990
DEPLOYMENT=""
HOSTS=""
SERVER=server-one
INTERVAL=30

usage() {
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2
    exit 1
}

while getopts "c:d:h:s:i:" opt; do
    case "$opt" in
        c) CONTROLLER=$OPTARG ;;
        d) DEPLOYMENT=$OPTARG ;;
        h) HOSTS=$OPTARG ;;
        s) SERVER=$OPTARG ;;
        i) INTERVAL=$OPTARG ;;
        *) usage ;;
    esac
done

[[ -n "$DEPLOYMENT" && -n "$HOSTS" ]] || usage
: "${JBOSS_MGMT_USER:?set JBOSS_MGMT_USER}"
: "${JBOSS_MGMT_PASS:?set JBOSS_MGMT_PASS}"
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

mgmt() {
    curl -sS --fail --max-time 10 --digest \
        -u "$JBOSS_MGMT_USER:$JBOSS_MGMT_PASS" \
        -H 'Content-Type: application/json' \
        -d "$1" "http://$CONTROLLER/management"
}

IFS=, read -ra HOST_LIST <<<"$HOSTS"

echo "time,host,active_sessions,sessions_created,expired_sessions,rejected_sessions,highest_session_count,heap_used_mb,heap_max_mb"

while true; do
    now=$(date '+%Y-%m-%dT%H:%M:%S')
    for host in "${HOST_LIST[@]}"; do
        server_addr="{\"host\":\"$host\"},{\"server\":\"$SERVER\"}"

        sessions=$(mgmt "{\"operation\":\"read-resource\",\"include-runtime\":true,\"address\":[$server_addr,{\"deployment\":\"$DEPLOYMENT\"},{\"subsystem\":\"undertow\"}]}" 2>/dev/null \
            | jq -r '.result
                     | [.["active-sessions"], .["sessions-created"], .["expired-sessions"],
                        .["rejected-sessions"], .["highest-session-count"]]
                     | map(. // "") | join(",")') || sessions=",,,,"

        heap=$(mgmt "{\"operation\":\"read-attribute\",\"name\":\"heap-memory-usage\",\"address\":[$server_addr,{\"core-service\":\"platform-mbean\"},{\"type\":\"memory\"}]}" 2>/dev/null \
            | jq -r '.result | [(.used / 1048576 | floor), (.max / 1048576 | floor)] | join(",")') || heap=","

        echo "$now,$host,$sessions,$heap"
    done
    sleep "$INTERVAL"
done
