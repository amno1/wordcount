#!/usr/bin/env bash
#
# Benchmark pure in-memory SIMD kernels (Generic vs AVX-2 vs AVX-512)
# Eliminates filesystem/pread I/O to measure raw CPU vector throughput.
# Usage: ./tools/bench-in-memory.sh [FILE]
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

FILE_SIZE=$(du -h "$FILE" | cut -f1)
echo "=========================================================="
echo " Pure In-Memory SIMD Kernel Benchmark (Zero I/O noise)"
echo " Target File: $FILE ($FILE_SIZE)"
echo "=========================================================="

"$SBCL_BIN" --noinform --no-userinit --non-interactive \
  --eval '(require :asdf)' \
  --eval '(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))' \
  --eval "(push (truename \"$ROOT_DIR\") asdf:*central-registry*)" \
  --eval '(asdf:load-system "wordcount")' \
  --eval '(in-package :wc)' \
  --eval "(let* ((fd (sb-posix:open \"$FILE\" sb-posix:o-rdonly))
                 (size (sb-posix:stat-size (sb-posix:fstat fd)))
                 (sap (sb-posix:mmap nil size sb-posix:prot-read sb-posix:map-private fd 0)))
            (sb-posix:posix-madvise sap size 3)
            (format t \"~%>>> 1. AVX-2 (Single-threaded pure compute):~%\")
            (time (count-lines-words-and-chars-ascii sap size #xFF))
            (format t \"~%>>> 2. AVX-512 (Single-threaded pure compute):~%\")
            (time (count-lines-words-and-chars-ascii-avx512 sap size #xFF))
            (format t \"~%>>> 3. Generic Scalar (Single-threaded pure compute):~%\")
            (time (count-lines-words-and-chars-ascii-generic sap size #xFF))
            (sb-posix:munmap sap size)
            (sb-posix:close fd))"

echo "=========================================================="
