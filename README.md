# wordcount — a GNU wc clone in Common Lisp

A SIMD-accelerated reimplementation of GNU `wc`, written in SBCL Common Lisp,
with three interchangeable backends — generic SWAR, AVX2, and AVX-512 — and a
multi-threaded scheduler that reads files with `pread` so that each worker
touches a different block of the same file in parallel.

> **Status: work in progress / experimental.**
> This is the synthesis of a series of performance experiments rather than a
> production-ready utility. Treat it as a reference implementation and a
> performance demonstration, not as a drop-in `wc`. Some less-used options and
> stdin edge cases are not yet on par with GNU `wc`.

---

## Contents

- [Motivation](#motivation)
- [Features](#features)
- [Requirements](#requirements)
- [Building](#building)
- [Quick start](#quick-start)
- [Benchmarks](#benchmarks)
- [Architecture](#architecture)
- [Documentation](#documentation)
- [License](#license)
- [Author](#author)

---

## Motivation

The project started as an attempt to answer one question: *can Common Lisp
run word-counting code at the same speed as hand-tuned C/C++?* The interesting
answer is not just “yes” — the fast paths here come from the same techniques
C and C++ implementations use:

1. **Vector processing** via AVX2 and AVX-512 (mask-register based, using
   `sb-simd` and a custom SBCL VOP for `popcnt`).
2. **`pread(2)` instead of `read(2)`** — positional reads let workers access
   disjoint byte ranges of a regular file without any inter-thread
   coordination and without shifting a shared file offset.
3. **Buffer reuse** and 64-byte alignment (`aligned_alloc`) so that SIMD
   loads are legal and caches behave.
4. **L2-cache-sized chunks** — the default `--chunk-size` (1 MiB) and the
   suggested thread count (8–10 on a Zen 5 laptop) are chosen so each worker's
   working set stays resident in L2.
5. **`posix_fadvise(POSIX_FADV_SEQUENTIAL)`** to nudge the kernel into
   aggressive readahead.
6. **Instant process teardown in application mode** — on CLI exit, `_exit(2)`
   terminates the process immediately (`sb-ext:exit :abort t`), delegating
   thread joining, memory deallocation, and descriptor closing to the OS kernel
   just as high-performance C and C++ utilities do. Full RAII cleanup is
   preserved in library mode.

The claim this project supports — verified by the benchmarks below — is
that on the same hardware, a Common Lisp implementation using the *same
algorithms* is within measurement noise of a hand-tuned C++ implementation
using the same algorithms. See [Comparison with fastlwc-mt](#comparison-with-fastlwc-mt).

---

## Features

- Line, word, byte and (ASCII / UTF-8) character counts.
- Strict UTF-8 mode (`--utf8-strict`) that rejects surrogate-half encodings
  (0xED followed by 0xA0–0xBF) and out-of-range lead bytes (< 0xC2 or > 0xF4).
- Three interchangeable kernels per operation:
  - **Generic** — pure-Lisp SWAR (`logcount` on 64-bit masks, 8 bytes at a
    time). Always available. No CPU-feature dependency.
  - **AVX2** — 256-bit vector kernels built on `sb-simd` (`u8.32`, `u64.4`,
    `u8.32-sad`, `u8.32-permute128`, ...). Emitted when the build host
    advertises AVX2.
  - **AVX-512** — 512-bit kernels using mask registers (`avx512bw:u8.64`,
    `mask8.64`, `mask64-bits`, `fpopcount`). Emitted when the build host
    advertises AVX-512 *and* the SBCL/sb-simd tree provides the AVX-512
    instruction-set additions.
- Multi-threaded scheduler with a reusable worker pool and `pread`-based
  block scheduling, falling back to a single-threaded linear read loop when
  `number-threads ≤ 1` or when reading from non-seekable streams.
- Runtime kernel selection via `--implementation` and a dispatch table,
  so the same binary can exercise all available kernels for benchmarking.
- Standardized public API (see `docs/library-manual.md`) with three tiers:
  raw SAP pointers, file descriptors, and paths.

---

## Requirements

- **SBCL** (the system uses `sb-sys:system-area-pointer`, `sb-thread`,
  `sb-posix`, and defines a custom VOP — see `docs/sbcl-notes.md`).
- **[`sb-simd`](https://github.com/martin-mx/sb-simd)**, for the AVX2 path.
- **A custom SBCL / sb-simd tree for AVX-512.** The AVX-512 backends depend
  on instruction-set additions (`avx512bw:u8.64`, mask types, `fpopcount`)
  that require the `evec` encoder branch in SBCL. The author maintains a branch
  that provides this; you must build SBCL against that branch if you want the
  AVX-512 kernels to compile.
- [`with-user-abort`](https://github.com/compufox/with-user-abort) and `uiop`
  (pulled in automatically as ASDF dependencies).
- Linux/Unix for `sb-posix` and `pread`.

> If you do **not** have the custom SBCL branch, everything still builds:
> `#+avx512` is simply off, and the AVX-512 kernels fall back to AVX2 or generic
> implementations in `dispatch.cl`. You can also force a portable generic build with
> `WC_NO_SIMD=1` (see [Building](#building)).

---

## Building

The build is a standard ASDF `program-op`:

```sh
# With SBCL on PATH:
sbcl --eval '(asdf:make :wordcount)'
# or, via make:
make
```

This produces a standalone executable named `wc` (set by
`:build-pathname "wc"` in `wordcount.asd`) with `wordcount::main` as the
entry point.

### Forcing a portable build

Set `WC_NO_SIMD=1` in the environment before building:

```sh
WC_NO_SIMD=1 sbcl --eval '(asdf:make :wordcount)'
```

This suppresses the `:avx2` and `:avx512` features at ASDF-time, so only the
generic SWAR kernels are compiled in. The resulting binary is **fully
portable** across all x86-64 machines (see `docs/sbcl-notes.md`).

---

## Quick start

```sh
# Same defaults as GNU wc: lines, words, bytes.
./wc tests/plato1g.txt
#  23220400 195711880 1073979760  tests/plato1g.txt

# Count lines, words, and UTF-8 characters, with strict validation,
# using the AVX-512 kernel and 10 worker threads.
./wc --lines --words --chars --utf8-strict \
     --implementation avx512 --number-threads 10 \
     tests/plato1g.txt

# Show which kernel actually ran (useful when checking fallbacks).
./wc --debug --implementation avx512 tests/plato1g.txt

# Read filenames from stdin, NUL-separated.
find . -name '*.txt' -print0 | ./wc --files0-from - --lines
```

Run `./wc --help` for the full option list, or see
[`docs/user-manual.md`](docs/user-manual.md).

---

## Benchmarks

### Test Environment

- **CPU:** AMD Ryzen AI 9 365 w/ Radeon 880M (Zen 5 architecture: 10 cores / 20 threads [4 Zen 5 + 6 Zen 5c], 10 MiB L2 cache, 24 MiB L3 cache, up to 5.09 GHz)
- **OS:** CachyOS Linux x86_64 (Kernel 7.2.10-1-cachyos, rolling release)
- **Workload:** 1 GiB text file (`tests/plato1g.txt`, 1,073,979,760 bytes, 23,220,400 lines, 195,711,880 words)

```sh
$ time ./wc tests/plato1g.txt --implementation <impl> --number-threads <N>
```

### Wall time (lower is better)

| Configuration             | real                 | user                 | sys                  |
|---------------------------|----------------------|----------------------|----------------------|
| `generic`, 1 thread       | 2.523 s              | 2.422 s              | 0.047 s              |
| `generic`, 10 threads     | 0.372 s              | 3.035 s              | 0.065 s              |
| `avx2`, 1 thread          | 0.087 s              | 0.044 s              | 0.047 s              |
| `avx2`, 10 threads        | 0.028 s              | 0.062 s              | 0.132 s              |
| `avx512`, 1 thread        | 0.064 s              | 0.022 s              | 0.043 s              |
| `avx512`, 10 threads      | 0.022 s – 0.026 s (med: 0.023 s) | 0.027 s – 0.045 s (med: 0.032 s) | 0.136 s – 0.183 s (med: 0.148 s) |
| **`fastlwc-mt` (ref.)**   | 0.021 s – 0.025 s (med: 0.023 s) | 0.104 s – 0.144 s (med: 0.109 s) | 0.223 s – 0.239 s (med: 0.232 s) |

### Throughput on the same file (higher is better)

| Configuration        | Throughput (GB/s) |
|----------------------|-------------------|
| `generic`, 1 thread  | ~0.43             |
| `generic`, 10 threads| ~2.89             |
| `avx2`, 1 thread     | ~12.3             |
| `avx512`, 1 thread   | ~16.8             |
| `avx2`, 10 threads   | ~38.4             |
| `avx512`, 10 threads | ~46.7             |
| **`fastlwc-mt`**     | ~46.7             |

### Tuning

The sweet spot on this Zen 5 machine is **~1 MiB chunks** and
**8–10 worker threads**. Larger chunks stop fitting in each thread's L2
cache (1 MiB per core); more threads than physical cores degrade the multi-threaded path. Both are
configurable via `--chunk-size` and `--number-threads` so you can find your
hardware's sweet spot.

### Comparison with `fastlwc-mt`

The reference implementation is
[`fastlwc`](https://github.com/expr-fi/fastlwc/) (C++, multi-threaded,
AVX-512-based). On this 1 GiB workload, the total wall-time of the
`avx512`, 10-thread `wc` binary (~0.023 s) and `fastlwc-mt` (~0.023 s) is
identical within measurement noise.

Notice the CPU-time breakdown:
- `fastlwc-mt` spends significantly more time in `sys` (~0.23 s vs ~0.15 s).
- `wc` spends very little time in `user` (~0.03 s vs ~0.11 s), demonstrating
  the efficiency of the compiled SBCL AVX-512 kernels.

The conclusion: the gap between fast C/C++ and fast Lisp here is
**the algorithm**, not the language. When implementing the same vector
processing and memory access patterns, Common Lisp on SBCL lands in the exact
same performance tier.

---

## Architecture

The project builds a single executable. Internally the code is organized
into four vertical layers plus a horizontal set of kernel modules:

```
              ┌──────────────────────────────────────────┐
              │  main / cli-options   (src/main.cl,       │
              │                        src/cli-options.cl)│
              └──────────────────┬───────────────────────┘
                                 │ CLI config
              ┌──────────────────▼───────────────────────┐
              │  wc-driver  (src/wc-driver.cl)            │
              │   coordinates per-file processing and     │
              │   output formatting                       │
              └──────────────────┬───────────────────────┘
                                 │
              ┌──────────────────▼───────────────────────┐
              │  scheduler  (src/scheduler.cl)            │
              │   process-fd / process-fd-linear /        │
              │   process-fd-mt ; worker pool             │
              └──────────────────┬───────────────────────┘
                                 │ per-block calls
              ┌──────────────────▼───────────────────────┐
              │  dispatch  (src/dispatch.cl)              │
              │   kernel-call macro ; dispatch-kernel     │
              └──────────────────┬───────────────────────┘
                                 │
              ┌──────────────────▼───────────────────────┐
              │  kernels/{lines,words,chars,              │
              │  lines-and-words,lines-and-chars,         │
              │  words-and-chars,lines-words-and-chars}   │
              │  × {generic, avx2, avx512}                │
              └──────────────────────────────────────────┘
```

- The **public API** (`src/api.cl`) exposes the functionality across three
  tiers: raw memory buffers (SAP), file descriptors (FD), and filesystem paths.
- The **kernels** are pure functions of `(sap, length, carry-state) →
  (values lines words chars)`. They perform no I/O. This allows
  `process-fd-mt` to parallelize cleanly: each worker calls the same kernel on
  its disjoint block, and the scheduler aggregates the results.
- The **carry state** (`init-ws`, `init-ed`) threads per-block context so
  that a block boundary that lands mid-UTF-8-sequence or between two
  whitespace bytes is counted without error. See
  `docs/library-manual.md#carry-state`.

---

## Documentation

- [`docs/user-manual.md`](docs/user-manual.md) — the CLI, every option, examples,
  and differences from GNU `wc`.
- [`docs/library-manual.md`](docs/library-manual.md) — the three API tiers,
  kernel families, backend selection, threading model, and symbol reference.
- [`docs/sbcl-notes.md`](docs/sbcl-notes.md) — SBCL-specific internals:
  feature detection, the `fpopcount` VOP, the extended `sb-posix` layer,
  `sb-simd` namespaces, thread primitives, foreign memory, and the AVX-512 build.

---

## License

GPL-3.0-or-later. See `wordcount.asd`.

---

## Author

Arthur Miller `<arthur.miller@live.com>`
