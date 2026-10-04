#!/usr/bin/env bash
#
# Compare wordcount (wc) vs fastlwc-mt head-to-head
# Usage: ./tools/bench-compare-fastlwc.sh [FILE]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
WC="$ROOT_DIR/wc"
FASTLWC="/home/arthur/repos/fastlwc/bin/fastlwc-mt"

if [[ ! -x "$WC" ]]; then
    echo "Building wc binary first..."
    make -C "$ROOT_DIR" all
fi

if [[ ! -x "$FASTLWC" ]]; then
    if [[ -d "/home/arthur/repos/fastlwc" ]]; then
        echo "Building fastlwc-mt first..."
        make -C "/home/arthur/repos/fastlwc"
    else
        echo "Error: fastlwc directory not found at /home/arthur/repos/fastlwc"
        exit 1
    fi
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
echo " Head-to-Head Comparison: wc vs fastlwc-mt"
echo " Target File: $FILE ($FILE_SIZE)"
echo "=========================================================="

TIMEFORMAT='   Time: %3R real, %3U user, %3S sys'

echo ""
echo ">>> Running 3 iterations for fastlwc-mt:"
for i in 1 2 3; do
    echo "Run $i:"
    time "$FASTLWC" "$FILE"
done

echo ""
echo ">>> Running 3 iterations for wc (AVX-512):"
for i in 1 2 3; do
    echo "Run $i:"
    time "$WC" "$FILE"
done

echo ""
echo "=========================================================="
