#!/usr/bin/env bash
# genie snp_rdma_test server loop (non-TEE peer). Re-accepts one client per iteration.
# Server just holds an 8 MiB MR and waits for the client's "done" (works for both --lat and --bw
# clients). usage: snp_server_loop.sh <dev> [snp_rdma_test path]
set -u
DEV=${1:?}; BIN=${2:-./snp_rdma_test}; PORT=18515
echo "snp server loop on $DEV:$PORT (Ctrl-C to stop)"
while true; do
  "$BIN" --server -d "$DEV" -s 8388608 --malloc --bw 1 -p "$PORT" 2>/dev/null
  sleep 0.2
done
