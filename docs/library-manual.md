# `wordcount` library manual

## Overview

The `wordcount` ASDF system compiles into a standalone executable but also
exports a public counting API suitable for embedding in other Common Lisp
programs. The API is organized in three *tiers* — SAP, FD, and Path —
so you can choose the level of abstraction you need:

**SAP tier** — operate directly on raw foreign-memory byte buffers. No I/O,
  no file handling. The kernels are pure functions of
  `(sap, length, carry-state) → (values lines words chars)`.

**FD tier** — operate on file descriptors. Handles seekable files
  with `pread` (multi-threaded) and non-seekable streams with `read` (linear),
  picks single- or multi-threaded scheduling, and returns standardized per-file counts.

**Path tier** — a high-level wrapper around the FD tier that manages opening
  and closing the file for you.

The system is SBCL-specific. See [`sbcl-notes.md`](sbcl-notes.md) for
the full list of SBCL extensions the library depends on.

## Packages

| Package            | Nickname | Purpose                                              |
|--------------------|----------|------------------------------------------------------|
| `wordcount`        | `wc`     | Public API. All exported symbols live here.          |
| `wordcount.system` | —        | Only used during ASDF system definition.             |
| `wc-benchmark`     | `wcb`    | Benchmark harness (exports `wc-simple`, `wc-suite`). |

The `wordcount` package `:use`s `cl`, `with-user-abort`, and (when AVX2 is
available) `sb-simd-avx2`. It uses `:local-nicknames` to bring in
`sb-simd-avx`, `sb-simd-sse4.1`, `sb-simd-avx512bw`, and `sb-simd-avx512f`
under short names without `:use`-ing them (see
[`sbcl-notes.md`](sbcl-notes.md#simd-package-namespaces) for why).

---

## The three tiers

### SAP tier

Every SAP function takes a `sb-sys:system-area-pointer` and a `fixnum` length.

Single counters return a single count:

```lisp
(count-lines-sap sap size &key implementation)               ; => lines
(count-words-sap sap size &key implementation)               ; => words
(count-chars-ascii-sap sap size &key implementation)         ; => chars
(count-chars-utf8-sap sap size &key implementation)          ; => chars
(count-chars-utf8-strict-sap sap size &key implementation)   ; => chars
(count-bytes-sap sap size &key implementation)               ; => size
```

Combined counters compute multiple metrics simultaneously and return multiple values:

```lisp
;; Lines and words
(count-lines-and-words-sap sap size &key implementation)
  ;; => (values lines words)

;; Lines and characters
(count-lines-and-chars-ascii-sap sap size &key implementation)
(count-lines-and-chars-utf8-sap sap size &key implementation)
(count-lines-and-chars-utf8-strict-sap sap size &key implementation)
  ;; => (values lines chars)

;; Words and characters
(count-words-and-chars-ascii-sap sap size &key implementation)
(count-words-and-chars-utf8-sap sap size &key implementation)
(count-words-and-chars-utf8-strict-sap sap size &key implementation)
  ;; => (values words chars)

;; Lines, words, and characters
(count-lines-words-and-chars-ascii-sap sap size &key implementation)
(count-lines-words-and-chars-utf8-sap sap size &key implementation)
(count-lines-words-and-chars-utf8-strict-sap sap size &key implementation)
  ;; => (values lines words chars)
```

SAP functions do not open, read, or close anything. The buffer must be
readable for `size` bytes for the duration of the call. There is no
protection against reading past `size` other than the function's own
bounds arithmetic (yes, you can and will segfault if you are not careful).

To call a SAP function on a Lisp `(vector (unsigned-byte 8))`, pin the vector:

```lisp
(let ((buf (make-array n :element-type '(unsigned-byte 8) ...)))
  (sb-sys:with-pinned-objects (buf)
    (let ((sap (sb-sys:vector-sap buf)))
      (wc:count-lines-sap sap n))))
```

### FD tier

```lisp
(count-lines-fd fd &key implementation number-threads chunk-size)
(count-words-fd fd &key implementation number-threads chunk-size)
(count-chars-ascii-fd fd &key implementation number-threads chunk-size)
(count-chars-utf8-fd fd &key implementation number-threads chunk-size)
(count-chars-utf8-strict-fd fd &key implementation number-threads chunk-size)
(count-bytes-fd fd &key implementation number-threads chunk-size)

;; Combined FD counters:
(count-lines-and-words-fd fd &key ...)
(count-lines-and-chars-ascii-fd fd &key ...)
(count-lines-and-chars-utf8-fd fd &key ...)
(count-lines-and-chars-utf8-strict-fd fd &key ...)
(count-words-and-chars-ascii-fd fd &key ...)
(count-words-and-chars-utf8-fd fd &key ...)
(count-words-and-chars-utf8-strict-fd fd &key ...)
(count-lines-words-and-chars-ascii-fd fd &key ...)
(count-lines-words-and-chars-utf8-fd fd &key ...)
(count-lines-words-and-chars-utf8-strict-fd fd &key ...)
```

All FD functions return the same standardized five values:

```
(values LINES WORDS CHARS BYTES ERROR)
```

with `ERROR` `nil` on success, or a condition object on failure. **Unused
count slots are zero** — e.g. `count-lines-fd` returns `(values LINES 0 0
BYTES NIL)`.

The FD tier:

- Detects seekability with `lseek`. Seekable files are read with
  `pread` (parallel) or `read` (linear); non-seekable descriptors use
  `read` in a linear loop.

- Applies `posix_fadvise(POSIX_FADV_SEQUENTIAL)` on the seekable path
  to hint the kernel for readahead.

- Short-circuits to `lseek(SEEK_END) - lseek(SEEK_CUR)` if only bytes
  were requested (`count-bytes-fd`). On seekable files, the file offset is preserved
  and no file read is performed.

- Uses the single-threaded path when `number-threads ≤ 1` or when the input
  is non-seekable.

- Does **not** close `fd`.

### Path tier

```lisp
(count-lines-path path &key implementation number-threads chunk-size)
(count-words-path path &key ...)
(count-chars-ascii-path path &key ...)
(count-chars-utf8-path path &key ...)
(count-chars-utf8-strict-path path &key ...)
(count-bytes-path path &key ...)

;; Combined Path counters:
(count-lines-and-words-path path &key ...)
(count-lines-and-chars-ascii-path path &key ...)
(count-lines-and-chars-utf8-path path &key ...)
(count-lines-and-chars-utf8-strict-path path &key ...)
(count-words-and-chars-ascii-path path &key ...)
(count-words-and-chars-utf8-path path &key ...)
(count-words-and-chars-utf8-strict-path path &key ...)
(count-lines-words-and-chars-ascii-path path &key ...)
(count-lines-words-and-chars-utf8-path path &key ...)
(count-lines-words-and-chars-utf8-strict-path path &key ...)
```

Path functions open `path` with `sb-posix:o-rdonly`, delegate to the matching FD
function, close the file in an `unwind-protect`, and return the same five
values. Opening errors are caught and reported as the `ERROR` slot with
all counts zeroed: `(values 0 0 0 0 error)`.

A `path` of `"-"` means stdin (fd 0).

### Convenience aliases

Four shortcuts correspond to the most common operations:

| Symbol                  | Equivalent to                |
|-------------------------|------------------------------|
| `count-lines`           | `count-lines-path`           |
| `count-words`           | `count-words-path`           |
| `count-bytes`           | `count-bytes-path`           |
| `count-lines-and-words` | `count-lines-and-words-path` |

---

## Kernel families

Each backend (`generic`, `avx2`, `avx512`) implements seven low-level
*families* of kernels in `src/kernels/`:

| Family                          | Raw kernel return | Notes                                     |
|---------------------------------|-------------------|-------------------------------------------|
| `count-lines-*`                 | `(values L W C)`  | `L` set; `W` and `C` are `nil`.           |
| `count-words-*`                 | `(values L W C)`  | `W` set.                                  |
| `count-chars-*`                 | `(values L W C)`  | `C` set.                                  |
| `count-lines-and-words-*`       | `(values L W C)`  | `L`, `W` set.                             |
| `count-lines-and-chars-*`       | `(values L W C)`  | `L`, `C` set.                             |
| `count-words-and-chars-*`       | `(values L W C)`  | `W`, `C` set.                             |
| `count-lines-words-and-chars-*` | `(values L W C)`  | All three set.                            |

Within each family, three variants exist:

- `-generic` — pure Lisp SWAR, always compiled.
- `<name>` (no suffix) — AVX2, compiled when `:avx2` is in `*features*`;
  otherwise falls back to the generic variant at dispatch.
- `-avx512` — AVX-512, compiled when `:avx512` is in `*features*`;
  otherwise falls back to AVX2 or generic.

The character modes are:


`-ascii`: Every byte is one ASCII character.

`-utf8` : "Fast" (lenient) UTF-8 - Counts bytes where `(byte & 0xC0) != 0x80`.
          Skips continuation bytes. Does not validate lead bytes.

`-utf8-strict`: Counts bytes that are ASCII or in `0xC2`–`0xF4`, *except* when
                the byte follows an `0xED` lead and is in `0xA0`–`0xBF` (surrogate halves).

### Internal chunk-boundary carry state

When a file or stream is partitioned across multiple blocks (by worker threads
in `process-fd-mt` or across sequential reads in `process-fd-linear`), two pieces
of internal state are threaded across block boundaries:

- **`init-ws`** — an `(unsigned-byte 8)`, `#xFF` if the byte immediately before
  the current block was whitespace (or start of file), `#x00` otherwise. Used
  by word-counting kernels to detect whether a word start straddles the block
  boundary.

- **`init-ed`** — an `(unsigned-byte 8)`, `1` if the byte immediately before the
  current block was `0xED`, `0` otherwise. Used by strict-UTF-8 kernels to
  detect and reject surrogate-half sequences that straddle the block boundary.

Both values are automatically managed internally by `process-fd-linear` and
`process-fd-mt` via `dispatch-kernel`. The public API (SAP, FD, and Path tiers)
does not expose these implementation details.

---

## Backend selection

### At build time

`:avx2` and `:avx512` are pushed onto `*features*` by an `eval-when` form
in `wordcount.asd`, based on `sb-impl:+internal-features+`. If the build
host reports `:avx2` or `:avx512`, the corresponding `#+`-guarded kernel
variants are compiled in. If `WC_NO_SIMD` is set in the environment at
build time, neither is pushed and only generic kernels are compiled.

### At runtime

`resolve-implementation` maps a user request (`:auto`, `:avx512`,
`:avx2`, `:generic`) to a concrete backend that the binary supports:

```lisp
(wc:resolve-implementation :auto)     ; => :avx512 / :avx2 / :generic
(wc:resolve-implementation :avx512)   ; => :avx512 or a warned fallback
(wc:resolve-implementation :avx2)     ; => :avx2 or a warned fallback
(wc:resolve-implementation :generic)  ; => :generic
```

The selected backend is passed to the `kernel-call` macro (see
`src/dispatch.cl`), which expands to the concrete function at compile time
based on `*features*`. The runtime `implementation` argument is therefore a
subset of what was compiled in.

> **Portability warning:** Backend selection does not perform a runtime CPUID
> check. A binary built on an AVX-512 host will attempt to execute AVX-512
> instructions. Running it on a machine without AVX-512 will result in a
> `SIGILL`. Build on target hardware or with `WC_NO_SIMD=1` for portability.
> See [`sbcl-notes.md#build-determinism`](sbcl-notes.md#build-determinism).

---

## The threading model

The scheduler lives in `src/scheduler.cl`. Its job is to split a file
into per-thread blocks, run the kernels, and merge the results.

### Pool lifecycle

```lisp
(wc::ensure-worker-pool nthreads chunk-size)  ; internal helper
(wc:shutdown-worker-pool)                    ; exported, idempotent
```

A worker pool is a global (`*worker-pool*`) guarded by `*pool-lock*`.
`ensure-worker-pool` creates one if none exists, or reuses/replaces the
existing pool if the requested thread count or chunk size is larger.
Workers are OS threads created with `sb-thread:make-thread`, coordinated with
`sb-thread:semaphore`s.

`shutdown-worker-pool` is safe to call multiple times, including from
condition handlers, and frees the per-worker aligned buffers via `alien-free`.
In standalone application mode (`main.cl`), upon exit, `_exit(2)` is invoked
directly (`sb-ext:exit :abort t`) without calling `shutdown-worker-pool` or
joining threads, letting the OS kernel reclaim virtual memory pages, threads,
and file descriptors instantly. In library mode, embedding applications should
call `shutdown-worker-pool` when done with parallel counting to prevent leaks.

### Per-file flow (`process-fd-mt`)

1. `posix_fadvise(fd, 0, size, POSIX_FADV_SEQUENTIAL)`.
2. Compute `blocks = ceil(size / chunk-size)`.
3. Fill a `work-item` with the fd, size, block count, dispatch mask,
   char mode, and backend.
4. Hand the work item to every worker, wake them with their start
   semaphores, and run worker 0 on the calling thread.
5. Each worker iterates `for block from my_tid below blocks by nthreads`,
   `pread`s `[block * chunk-size - 1, (block + 1) * chunk-size)` — note
   the one-byte overlap: the byte *before* each block is read into a
   one-byte look-behind position so that `init-ws` / `init-ed` can be derived
   from the preceding block's last byte without inter-thread locking.
6. The calling thread waits for `nthreads - 1` completions on the pool
   done-semaphore, then sums `t-lines`, `t-words`, `t-chars` across workers.
7. If any worker signalled an error, the call returns
   `(values 0 0 0 size ERROR)`; otherwise the summed counts.

Worker 0 is the calling thread, so `number-threads` is the *total*
number of participating threads.

---

## Testing

The repository ships a Parachute-based correctness suite in
`tests/test-avx512-kernels.lisp`. It tests the AVX2, AVX-512, and generic
kernels against each other on generated buffers across:

- vector widths (64-byte, 128-byte, and small boundary sizes);
- boundary-straddling whitespace and surrogate-half sequences;
- full public API tests (SAP, FD, Path, and offset preservation);
- a 5 MB prefix of `tests/plato1g.txt`.

Run it with `make test`:

```sh
make test
```

Or invoke directly with SBCL:

```sh
sbcl --noinform --non-interactive --load tests/test-avx512-kernels.lisp
```

---

## Performance notes

- The 1 MiB default chunk size is tuned for modern L2 cache sizes (1 MiB per
  core on AMD Zen 5). Benchmark your own file sizes and cache hierarchy.
- Byte-only counting (`count-bytes-*`) never reads seekable files; it uses
  `lseek` and returns immediately.
- Multi-threading is enabled whenever `number-threads > 1`. With default settings
  (8 threads, 1 MiB chunk size), 8 MiB is the empirical saturation point where every
  worker gets 1 full block of work. Users can tune `number-threads` and `chunk-size`
  to find the optimal break-even point for their hardware. See `tools/bench-threshold-report.md`
  for the empirical threshold benchmark.
- On AMD Zen 5 (10 cores / 20 threads), the utility achieves ~16.8 GB/s
  single-thread AVX-512 and ~46.7 GB/s multi-threaded (~0.023 s wall time) on
  a 1 GiB file. See the README benchmark section for details.
