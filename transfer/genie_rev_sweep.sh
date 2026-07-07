#!/usr/bin/env bash
# non-TEE -> SEV: genie is the RDMA INITIATOR into the SEV guest (--reverse-roles), so genie
# measures + emits the CSV. The SEV guest runs guest_rev_loop.sh (passive, dials out — NAT).
# genie is the TCP server; the guest connects per measurement. Needs the --lat-capable binary.
# usage: genie_rev_sweep.sh <dev> <out.csv> <snp_rdma_test-with-lat path>
set -u
DEV=${1:?e.g. ibp23s0}; OUT=${2:?out.csv}; BIN=${3:?path to --lat binary}; PORT=18515
SIZES="64 256 1024 4096 16384 65536 262144 1048576 4194304"; CFG=nonTEE-to-SEV
[ -f "$OUT" ] || echo "config,tool,op,metric,size_bytes,avg,typ_or_p50,p99,unit" > "$OUT"
for op in write read; do
  RD=""; [ "$op" = read ] && RD="--bw-read"
  for sz in $SIZES; do
    o=$("$BIN" --server --reverse-roles --malloc -d "$DEV" -p "$PORT" -s "$sz" --lat 1000 $RD 2>&1)
    echo "$o" | grep -oE "min [0-9.]+ avg [0-9.]+ p50 [0-9.]+ p99 [0-9.]+ max [0-9.]+" | \
      awk -v c="$CFG" -v op="$op" -v s="$sz" '{print c",snp_lat,"op",lat,"s","$4","$6","$8",us"}' >> "$OUT"
    o=$("$BIN" --server --reverse-roles --malloc -d "$DEV" -p "$PORT" -s "$sz" --bw 4000 --bw-batch 64 $RD 2>&1)
    echo "$o" | grep -oE "=> [0-9.]+ Gbit/s" | \
      awk -v c="$CFG" -v op="$op" -v s="$sz" '{print c",snp_bw,"op",bw,"s","$2","$2",,Gbps"}' >> "$OUT"
  done
done
echo "wrote $OUT ($(($(wc -l <"$OUT")-1)) rows)"; echo "=== CSV ==="; cat "$OUT"
