#!/usr/bin/env bash
# memory node on genie (non-TEE), SELF-HEALING: memnode exits when the compute detaches (TCP
# EOF); this loop respawns it with a fresh QP so the compute can reconnect without a manual
# restart. usage: run-memnode.sh [dev] [tcp_port] [nslots] [value_size]
set -u
DEV=${1:-ibp23s0}; PORT=${2:-18600}; NSLOTS=${3:-262144}; VSIZE=${4:-${KVS_VSIZE:-64}}
while true; do
  ./memnode -d "$DEV" -p "$PORT" -n "$NSLOTS" -V "$VSIZE"
  echo "[run-memnode] memnode exited — respawn in 0.5s"
  sleep 0.5
done
