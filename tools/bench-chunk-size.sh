#!/usr/bin/env bash
#
# Benchmark chunk/buffer size scaling in wordcount (wc)
# Usage: ./tools/bench-chunk-size.sh [FILE]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
WC="$ROOT_DIR/wc"

if [[ ! -x "$WC" ]]; then
    echo "Building wc binary first..."
    make -C "$ROOT_DIR" all
fi

FILE="${1:-"$ROOT_DIR/tests/plato1g.txt"}"

if [[ ! -f "$FILE" ]]; then
    if [[ -f "$ROOT_DIR/tests/plato100.txt" ]]; then
        FILE="$ROOT_DIR/tests/plato100.txt"
    else
        echo "Error: Test file '$FILE' not found."
        exit 1
    fi
fi

FILE_SIZE=$(du -h "$FILE" | cut -f1)
echo "=========================================================="
echo " Benchmarking Buffer / Chunk Size on $FILE ($FILE_SIZE)"
echo " Demonstrating Zen 5 L2 cache residency (<= 1MB) vs spill"
echo "=========================================================="
printf "%-18s %-12s %-12s %-12s\n" "Buffer Size" "Real Time" "User Time" "Sys Time"
echo "----------------------------------------------------------"

TIMEFORMAT='%3R %3U %3S'

SIZES=(
    65536      # 64 KB
    131072     # 128 KB
    262144     # 256 KB
    524288     # 512 KB
    1048576    # 1 MB  (L2 Sweet Spot)
    2097152    # 2 MB  (Spills to L3)
    4194304    # 4 MB
    8388608    # 8 MB
    16777216   # 16 MB
)

for sz in "${SIZES[@]}"; do
    if (( sz >= 1048576 )); then
        LABEL="$((sz / 1048576)) MB"
    else
        LABEL="$((sz / 1024)) KB"
    fi
    TIME_OUTPUT=$( { time "$WC" --chunk-size "$sz" "$FILE" >/dev/null; } 2>&1 )
    read -r real_t user_t sys_t <<< "$TIME_OUTPUT"
    printf "%-18s %-12ss %-12ss %-12ss\n" "$LABEL ($sz)" "$real_t" "$user_t" "$sys_t"
done

echo "=========================================================="
