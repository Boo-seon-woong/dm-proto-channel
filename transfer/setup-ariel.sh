#!/usr/bin/env bash
# memcached_test2 v2 — ARIEL-SIDE service setup (semi-automated).
# Run this ON ARIEL (with sudo) to bring up the service endpoints that genie's memtier will hit.
# It does NOT run memtier (that is genie's v2-runner.sh). It sets up IPoIB + the two services
# (stock memcached, KVS compute) and prints the endpoints to announce to genie.
#
#   ./setup-ariel.sh nonTEE     # guest DOWN: services on the ariel HOST
#   ./setup-ariel.sh SEV        # guest UP:   services INSIDE the SEV guest
#   ./setup-ariel.sh stop       # stop services started by this script (host side)
#
# Everything is overridable by env vars (defaults below). Review before running as root.
set -euo pipefail
MODE=${1:?usage: setup-ariel.sh nonTEE|SEV|stop}

# ---- tunables (override via env) ------------------------------------------------------------
IPOIB_HOST=${IPOIB_HOST:-10.99.0.1}          # ariel host IPoIB addr (non-TEE)
IPOIB_GUEST=${IPOIB_GUEST:-10.99.0.3}        # ariel guest IPoIB addr (SEV)
IPOIB_MASK=${IPOIB_MASK:-24}
HOST_IB_DEV=${HOST_IB_DEV:-ibp193s0}         # host RDMA device (guest down)
GUEST_IB_DEV=${GUEST_IB_DEV:-ibp1s0}         # guest RDMA device (guest up)
GENIE_MEMNODE_IP=${GENIE_MEMNODE_IP:-10.99.0.2}   # genie memnode, IPoIB
MEMNODE_PORT=${MEMNODE_PORT:-18600}
NSLOTS=${NSLOTS:-262144}
STOCK_PORT=${STOCK_PORT:-11211}
KVS_PORT=${KVS_PORT:-11212}
KVS_DIR=${KVS_DIR:-$HOME/2026/ITRC-RDMA/memcached-rdma/common}
GUEST_SSH=${GUEST_SSH:-"ssh -o StrictHostKeyChecking=no -i $HOME/.ssh/snp_guest -p 2222 ubuntu@localhost"}
GUESTCTL=${GUESTCTL:-$HOME/2026/sev/guestctl.sh}

say() { echo "[setup-ariel:$MODE] $*"; }

# find the netdev name for an IB device (e.g. ibp193s0 -> the ib0-like iface)
ib_netdev() { ls "/sys/class/infiniband/$1/device/net" 2>/dev/null | head -1; }

assign_ipoib_host() {
  local nd; nd=$(ib_netdev "$HOST_IB_DEV") || true
  [ -n "${nd:-}" ] || { echo "ERR: no netdev for $HOST_IB_DEV (is the guest holding the IB NIC?)"; exit 1; }
  say "IPoIB: $IPOIB_HOST/$IPOIB_MASK on $nd"
  sudo ip link set "$nd" up
  sudo ip addr replace "$IPOIB_HOST/$IPOIB_MASK" dev "$nd"
  ip addr show "$nd" | grep -w inet || true
}

start_stock_host() {
  command -v memcached >/dev/null || { echo "ERR: install memcached (1.6.24, -I 4m)"; exit 1; }
  say "stock memcached on $IPOIB_HOST:$STOCK_PORT (local DRAM, -I 4m)"
  pkill -x memcached 2>/dev/null || true; sleep 0.5
  memcached -p "$STOCK_PORT" -l "$IPOIB_HOST" -m 1024 -t 1 -I 4m -d
}

start_kvs_host() {
  say "build + start KVS compute (host) -> RDMA to $GENIE_MEMNODE_IP:$MEMNODE_PORT, listen :$KVS_PORT"
  ( cd "$KVS_DIR" && make >/dev/null )
  pkill -x compute 2>/dev/null || true; sleep 0.5
  setsid nohup "$KVS_DIR/compute" -d "$HOST_IB_DEV" -m "$GENIE_MEMNODE_IP" -r "$MEMNODE_PORT" \
    -l "$KVS_PORT" -n "$NSLOTS" </dev/null >/tmp/kvs-compute-host.log 2>&1 & disown
  sleep 4; tail -3 /tmp/kvs-compute-host.log
}

case "$MODE" in
  nonTEE)
    assign_ipoib_host
    start_stock_host
    start_kvs_host
    echo
    say "ENDPOINTS (announce to genie):"
    echo "  stock-TCP-remote-nonTEE   $IPOIB_HOST:$STOCK_PORT"
    echo "  KVS-RDMA-remote-nonTEE    $IPOIB_HOST:$KVS_PORT"
    ;;

  SEV)
    say "bring guest up + set up services INSIDE the guest"
    sudo -n "$GUESTCTL" up >/dev/null 2>&1 || say "(guestctl up: check manually)"
    for i in $(seq 1 40); do $GUEST_SSH 'echo up' >/dev/null 2>&1 && break; sleep 5; done
    $GUEST_SSH "bash -s" <<EOS
set -e
NDG=\$(ls /sys/class/infiniband/$GUEST_IB_DEV/device/net 2>/dev/null | head -1)
sudo ip link set \$NDG up; sudo ip addr replace $IPOIB_GUEST/$IPOIB_MASK dev \$NDG
lsmod | grep -q '^mlx5_ib' || sudo insmod ~/covlib/mlx5_ib.ko 2>/dev/null || true
lsmod | grep -q '^snp_shared' || sudo insmod ~/snp-rdma/snp_shared.ko cachemode=uc 2>/dev/null || true
command -v memcached >/dev/null && { pkill -x memcached 2>/dev/null || true; sleep 0.5; \
  memcached -p $STOCK_PORT -l $IPOIB_GUEST -m 1024 -t 1 -I 4m -d; } || echo "WARN: install memcached in guest"
export MLX5_COHERENT_QP=1 LD_LIBRARY_PATH=\$HOME/covlib
pkill -x compute-cov 2>/dev/null || true; sleep 0.5
setsid nohup ~/compute-cov -d $GUEST_IB_DEV -m $GENIE_MEMNODE_IP -r $MEMNODE_PORT -l $KVS_PORT -n $NSLOTS -S \
  </dev/null >/tmp/kvs-compute-guest.log 2>&1 & disown
sleep 5; tail -3 /tmp/kvs-compute-guest.log
EOS
    echo
    say "ENDPOINTS (announce to genie):"
    echo "  stock-TCP-remote-SEV          $IPOIB_GUEST:$STOCK_PORT"
    echo "  KVS-RDMA-remote-SEV-correct   $IPOIB_GUEST:$KVS_PORT"
    ;;

  stop)
    pkill -x compute 2>/dev/null || true; pkill -x memcached 2>/dev/null || true
    say "host services stopped (guest services: run stop logic in guest if needed)"
    ;;

  *) echo "usage: setup-ariel.sh nonTEE|SEV|stop"; exit 1;;
esac
