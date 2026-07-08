#!/usr/bin/env bash
# memcached_test2 v2 runner — runs ON THE CLIENT HOST (genie), drives memtier against a REMOTE
# service endpoint over the physical network. Enforces the memcached_test2.md hard gate:
# no loopback / no 127.0.0.1 / no ssh -L. One invocation = one config's full sweep.
#
# Usage:
#   v2-runner.sh <config> <service_ip> <service_port> <run_dir>
#     config       e.g. stock-TCP-remote-nonTEE | KVS-RDMA-remote-SEV-correct
#     service_ip   REMOTE ip of the service endpoint (NOT loopback)
#     service_port memcached-text port
#     run_dir      results/memcached_test2/<YYYYMMDD-HHMMSS>-remote-two-server
#
# Env overrides: VSIZES, MIXES, CLIENTS, THREADS, SECONDS, RUNS, KEYMAX
set -u
CONFIG=${1:?config}; SERVICE_IP=${2:?service_ip}; SERVICE_PORT=${3:?service_port}; RUN_DIR=${4:?run_dir}

VSIZES=${VSIZES:-"64 1024 4096 16384 65536 262144"}   # 64B..256KiB
MIXES=${MIXES:-"RO WO"}                                 # read-only, write-only
CLIENTS=${CLIENTS:-8}; THREADS=${THREADS:-1}; SECONDS=${SECONDS:-30}; RUNS=${RUNS:-3}
KEYMAX=${KEYMAX:-100000}

RAW="$RUN_DIR/raw-terminal"; mkdir -p "$RAW" "$RUN_DIR/parsed" "$RUN_DIR/reports" "$RUN_DIR/counters"
CMDS="$RUN_DIR/commands.sh"

# ---- hard gate: refuse loopback / lo-route / tunnel (memcached_test2.md §212) --------------
preflight() {
  local out="$1"
  {
    echo "### preflight $(date -u +%FT%TZ)"
    echo "client_hostname=$(hostname)"
    echo "client_addrs=$(hostname -I 2>/dev/null)"
    echo "service=$CONFIG $SERVICE_IP:$SERVICE_PORT"
    getent hosts "$SERVICE_IP" 2>/dev/null && echo "(resolved above)"
  } | tee -a "$out"

  case "$SERVICE_IP" in
    127.*|localhost|::1) echo "INVALID: SERVICE_IP is loopback: $SERVICE_IP" | tee -a "$out" >&2; return 2;;
  esac
  local route; route="$(ip route get "$SERVICE_IP" 2>&1)" || { echo "INVALID: no route to $SERVICE_IP" | tee -a "$out" >&2; return 2; }
  echo "ip route get $SERVICE_IP -> $route" | tee -a "$out"
  if echo "$route" | grep -Eq ' dev lo | local '; then
    echo "INVALID: service route is loopback/local: $route" | tee -a "$out" >&2; return 2
  fi
  if env | grep -Eq 'SSH_|PROXY|TUNNEL'; then
    echo "CHECK: proxy/tunnel env present — verify no ssh -L is in the measured path" | tee -a "$out"
  fi
  return 0
}

ratio_for() { [ "$1" = RO ] && echo "0:1" || echo "1:0"; }

# populate keys before a read-only run so GETs can hit (memcached_test2.md §388)
populate() {
  local vsize="$1"
  memtier_benchmark -s "$SERVICE_IP" -p "$SERVICE_PORT" -P memcache_text \
    --ratio=1:0 --data-size="$vsize" --clients="$CLIENTS" --threads="$THREADS" \
    --key-maximum="$KEYMAX" --requests="$KEYMAX" --hide-histogram >/dev/null 2>&1
}

echo "# $CONFIG -> $SERVICE_IP:$SERVICE_PORT  (vsizes: $VSIZES; mixes: $MIXES; c$CLIENTS t$THREADS ${SECONDS}s x$RUNS)" >> "$CMDS"

for mix in $MIXES; do
  ratio=$(ratio_for "$mix")
  for vsize in $VSIZES; do
    [ "$mix" = RO ] && populate "$vsize"
    for run in $(seq 1 "$RUNS"); do
      out="$RAW/${CONFIG}_${mix}_${vsize}_run${run}.txt"
      : > "$out"
      if ! preflight "$out"; then echo "SKIP (preflight fail): $out"; continue; fi
      cmd="memtier_benchmark -s $SERVICE_IP -p $SERVICE_PORT -P memcache_text --ratio=$ratio --data-size=$vsize --clients=$CLIENTS --threads=$THREADS --test-time=$SECONDS --key-maximum=$KEYMAX --hide-histogram"
      echo "$cmd" | tee -a "$out" | tee -a "$CMDS" >/dev/null
      echo "--- memtier output ---" >> "$out"
      $cmd 2>&1 | tee -a "$out"
      echo "[done] $out"
    done
  done
done
echo "=== $CONFIG sweep complete → $RAW ==="
