#!/usr/bin/env bash
#
# Benchmark: Linear vs Multi-threaded (MT) execution across file sizes
# Measures cold-start pool allocation and warm-pool semaphore synchronization costs
# to demonstrate why the 8 MiB threshold in scheduler.cl is optimal.
#
# Usage: ./tools/bench-threshold.sh [BASE_FILE]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SBCL_BIN="/home/arthur/repos/sb-simd-512/run-sbcl.sh"

FILE="${1:-"$ROOT_DIR/tests/plato1g.txt"}"

if [[ ! -f "$FILE" ]]; then
    if [[ -f "$ROOT_DIR/tests/plato100.txt" ]]; then
        FILE="$ROOT_DIR/tests/plato100.txt"
    elif [[ -f "$ROOT_DIR/tests/plato.org" ]]; then
        FILE="$ROOT_DIR/tests/plato.org"
    else
        echo "Error: Base test file '$FILE' not found."
        exit 1
    fi
fi

chmod +x "$SCRIPT_DIR/bench-threshold.sh"

"$SBCL_BIN" --noinform --non-interactive \
  --eval "(require :asdf)" \
  --eval "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))" \
  --eval "(push (truename \"$ROOT_DIR\") asdf:*central-registry*)" \
  --eval "(asdf:load-system \"wordcount\")" \
  --load "$SCRIPT_DIR/bench-threshold.lisp" \
  --eval "(wc::run-threshold-benchmark \"$FILE\")" \
  --eval "(sb-ext:exit)"
