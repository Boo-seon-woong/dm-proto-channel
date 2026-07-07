#!/usr/bin/env bash
# non-TEE -> SEV, ONE connection: genie initiator does the whole write/read x {lat,bw} x 9-size
# matrix over a single QP (--rev-sweep). The SEV guest connects ONCE (passive, one MR — no churn).
# usage: genie_rev_sweep1.sh <dev> <out.csv> <snp_rdma_test-with-rev-sweep>
set -u
DEV=${1:?}; OUT=${2:?}; BIN=${3:?}; PORT=18515
echo "config,tool,op,metric,size_bytes,avg,typ_or_p50,p99,unit" > "$OUT"
echo "genie rev-sweep server up on $DEV:$PORT — waiting for the guest to connect once..."
"$BIN" --server --reverse-roles --rev-sweep --malloc -d "$DEV" -s 4194304 -p "$PORT" 2>/tmp/rev.err | grep '^nonTEE-to-SEV,' >> "$OUT"
echo "wrote $OUT ($(($(wc -l <"$OUT")-1)) rows)"; echo "=== stderr tail ==="; tail -3 /tmp/rev.err; echo "=== CSV ==="; cat "$OUT"
