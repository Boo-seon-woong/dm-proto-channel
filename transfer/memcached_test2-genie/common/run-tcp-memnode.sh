#!/usr/bin/env bash
# TCP-backend memory node respawn loop (exits on compute detach). usage: run-tcp-memnode.sh [port] [nslots] [value_size]
PORT=${1:-18601}; NSLOTS=${2:-262144}; VSIZE=${3:-${KVS_VSIZE:-64}}
while true; do ./tcp_memnode -p "$PORT" -n "$NSLOTS" -V "$VSIZE"; echo "[respawn] tcp_memnode restarting..."; sleep 0.5; done
