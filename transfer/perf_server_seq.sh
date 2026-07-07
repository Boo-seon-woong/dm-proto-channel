#!/usr/bin/env bash
# perftest server sequence (run on the non-TEE peer, e.g. genie). Runs each of the 4
# tools as a server (waits for one client each), in order. Re-run this per client config.
# usage: perf_server_seq.sh <dev>   (e.g. ibp23s0)
set -u
DEV=${1:?}; PORT=18515
for t in write_lat read_lat write_bw read_bw; do
  echo "== server: ib_$t -a (waiting for client) =="
  ib_${t} -a -d "$DEV" -p "$PORT" --report_gbits
done
echo "server sequence done"
