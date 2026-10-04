#!/usr/bin/env bash
#
# Benchmark AVX-512 vs AVX-2 implementations in wordcount (wc)
# Usage: ./tools/bench-avx512-vs-avx2.sh [FILE]
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
echo " AVX-512 vs AVX-2 Benchmark on $FILE ($FILE_SIZE)"
echo "=========================================================="

run_perf() {
    local label="$1"
    shift
    echo ""
    echo "----------------------------------------------------------"
    echo " >>> $label"
    echo " Command: $WC $* $FILE"
    echo "----------------------------------------------------------"
    if command -v perf >/dev/null 2>&1; then
        perf stat "$WC" "$@" "$FILE"
    else
        time "$WC" "$@" "$FILE"
    fi
}

# 1. Default mode (Lines, Words, Bytes)
run_perf "Default Mode: AVX-2" --implementation avx2
run_perf "Default Mode: AVX-512" --implementation avx512

# 2. UTF-8 Character Counting (-m)
run_perf "UTF-8 Mode (-m): AVX-2" -m --implementation avx2
run_perf "UTF-8 Mode (-m): AVX-512" -m --implementation avx512

# 3. Strict UTF-8 Character Counting (-m --utf8-strict)
run_perf "Strict UTF-8 Mode: AVX-2" -m --utf8-strict --implementation avx2
run_perf "Strict UTF-8 Mode: AVX-512" -m --utf8-strict --implementation avx512

echo ""
echo "=========================================================="
echo " Benchmark Complete."
echo "=========================================================="
