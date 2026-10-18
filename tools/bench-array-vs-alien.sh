#!/usr/bin/env bash
#
# Benchmark: Alien Buffer vs Pinned Typed Lisp Array
# Compares:
#   1. Alien Buffer (aligned_alloc 64-byte aligned, zero GC pressure)
#   2. Typed Lisp Array (pinned simple-array (unsigned-byte 8), manual alignment)
# Usage: ./tools/bench-array-vs-alien.sh [FILE]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
SBCL_BIN="${SBCL_BIN:-"$ROOT_DIR/../../sb-simd-512/run-sbcl.sh"}"
if [[ ! -x "$SBCL_BIN" ]]; then
    SBCL_BIN="sbcl"
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

chmod +x "$SCRIPT_DIR/bench-array-vs-alien.sh"

"$SBCL_BIN" --noinform --non-interactive \
  --eval "(require :asdf)" \
  --eval "(load (merge-pathnames \"quicklisp/setup.lisp\" (user-homedir-pathname)))" \
  --eval "(push (truename \"$ROOT_DIR\") asdf:*central-registry*)" \
  --eval "(asdf:load-system \"wordcount\")" \
  --load "$SCRIPT_DIR/bench-array-vs-alien.lisp" \
  --eval "(wc::run-comparison \"$FILE\")" \
  --eval "(sb-ext:exit)"
