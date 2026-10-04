#!/usr/bin/env bash
#
# Benchmark thread scaling for wordcount (wc)
# Usage: ./tools/bench-scaling.sh [FILE]
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
        echo "Run 'make test' or generate test data first."
        exit 1
    fi
fi

FILE_SIZE=$(du -h "$FILE" | cut -f1)
echo "=========================================================="
echo " Benchmarking Thread Scaling on $FILE ($FILE_SIZE)"
echo "=========================================================="
printf "%-10s %-12s %-12s %-12s\n" "Threads" "Real Time" "User Time" "Sys Time"
echo "----------------------------------------------------------"

TIMEFORMAT='%3R %3U %3S'

for nth in 1 2 4 8 10 12 16 20; do
    TIME_OUTPUT=$( { time "$WC" --number-threads "$nth" "$FILE" >/dev/null; } 2>&1 )
    read -r real_t user_t sys_t <<< "$TIME_OUTPUT"
    printf "%-10s %-12ss %-12ss %-12ss\n" "$nth" "$real_t" "$user_t" "$sys_t"
done

echo "=========================================================="
