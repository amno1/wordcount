# SBCL-specific implementation notes

This document records every place where the code relies on SBCL
internals, non-standard extensions, or a non-stock SBCL/sb-simd build.
The sources have `#-sbcl (error ...)` at the top of each file.

## Why SBCL?

The kernels and scheduler need:

- **Raw foreign memory** — `sb-sys:system-area-pointer`,
  `sb-sys:sap-ref-8/64`, `sb-sys:sap+`. The whole SAP tier is built on
  these, and AVX-512 loads/stores require 64-byte alignment that
  `sb-sys:vector-sap` on a standard Lisp array does not guarantee.
- **SIMD intrinsics** — `sb-simd`, which is an SBCL contrib library.
- **A custom VOP** — the `fpopcount` virtual operation (see below).
- **`sb-thread`** — for the worker pool.
- **`sb-posix`** — for `open`, `close`, `pread`, `lseek`, `read`,
  `posix_fadvise`, `aligned_alloc`, and `free`.

## Feature detection at build time

`wordcount.asd` begins with:

```lisp
#+sbcl
(progn
  (when (member :avx2 (symbol-value 'sb-impl:+internal-features+))
    (unless (uiop:getenv "WC_NO_SIMD")
      (pushnew :avx2 *features*)))
  (when (member :avx512 (symbol-value 'sb-impl:+internal-features+))
    (unless (uiop:getenv "WC_NO_SIMD")
      (pushnew :avx512 *features*))))
```

Notes:

- This runs while ASDF is loading the system definition — i.e. **at
  build time**, not at the run time of the resulting executable.
- `sb-impl:+internal-features+` is an SBCL internal symbol reflecting the
  CPU features detected by the build host's SBCL at startup.
- `WC_NO_SIMD` is consulted **here only**. Setting it at runtime has no
  effect; the compiled binary already contains (or does not contain)
  SIMD kernels.

## The `fpopcount` VOP

`src/common.cl` extends SBCL's compiler and VM packages:

```lisp
(in-package "SB-C")
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defknown wc::fpopcount ((unsigned-byte 64)) (unsigned-byte 64)
      (flushable movable)
    :overwrite-fndb-silently t))

(in-package "SB-VM")
(eval-when (:compile-toplevel :load-toplevel :execute)
  (define-vop (wc::fpopcount)
    (:policy :fast-safe)
    (:translate wc::fpopcount)
    (:args (x :scs (unsigned-reg)))
    (:arg-types unsigned-num)
    (:results (r :scs (unsigned-reg)))
    (:result-types unsigned-num)
    (:generator 1
      (inst popcnt r x))))
```

- `fpopcount` maps directly to the x86 `POPCNT` instruction. It is used by the
  AVX-512 kernels to count bits in 64-bit mask registers (`popcount64`).
  It is not used by the generic or AVX2 paths.
- `:overwrite-fndb-silently t` ensures that reloading the system in the
  same image does not emit warnings about redefining the `defknown`.
- `(in-package "SB-C")` and `(in-package "SB-VM")` reach into SBCL internal
  packages.
- `POPCNT` is emitted unconditionally by the VOP. All x86-64 CPUs with
  AVX2 or AVX-512 support `POPCNT` (introduced around 2008 with Nehalem / SSE4.2).

## The extended `sb-posix` layer

`src/common.cl` re-opens `sb-posix` and adds foreign-function bindings:

```lisp
(in-package :sb-posix)
#+unix
(eval-when (:compile-toplevel :load-toplevel :execute)
  (declaim (inline sysconf pread posix-read aligned-alloc alien-free posix-fadvise))

  (define-call "posix_fadvise" int minusp
    (fd file-descriptor) (offset off-t) (size off-t) (advice int))

  (unless (fboundp 'sysconf)
    (define-alien-routine sysconf int (name int)))

  (define-alien-routine ("read" posix-read) sb-alien:long
    (fd sb-alien:int)
    (buf sb-sys:system-area-pointer)
    (count sb-alien:size-t))

  (define-alien-routine ("pread" pread) sb-alien:long
    (fd sb-alien:int)
    (buf sb-sys:system-area-pointer)
    (count sb-alien:unsigned-long)
    (offset sb-alien:long))

  (define-alien-routine ("aligned_alloc" aligned-alloc) sb-sys:system-area-pointer
    (alignment sb-alien:size-t)
    (size sb-alien:size-t))

  (define-alien-routine ("free" alien-free) sb-alien:void
    (ptr sb-sys:system-area-pointer))

  (export 'sysconf :sb-posix)
  (export 'posix-fadvise :sb-posix)
  (export 'posix-read :sb-posix)
  (export 'pread :sb-posix)
  (export 'aligned-alloc :sb-posix)
  (export 'alien-free :sb-posix))
```

Details for each binding:

- **`posix_fadvise`** — bound via `define-call`, used with
  `POSIX_FADV_SEQUENTIAL` (advice 2) on seekable files before parallel reading.
- **`sysconf`** — used by `ncpus`, called with `_SC_NPROCESSORS_ONLN = 84`
  (defined as `+sc-nprocessors-onln+` in `src/common.cl`). Guarded with
  `unless (fboundp 'sysconf)` to avoid collisions if SBCL exports it in the future.
- **`posix-read`** — raw libc `read(2)` into a SAP. Stock SB-POSIX only
  exposes a `read` that returns a Lisp string; the scheduler reads directly into
  aligned foreign buffers.
- **`pread`** — the linchpin of the multi-threaded scheduler. `pread(2)`
  reads from a given offset without altering the file offset, allowing N
  workers to read N disjoint blocks of one file concurrently without locking.
- **`aligned_alloc` / `free`** — AVX-512 loads and stores require 64-byte
  alignment. The scheduler allocates per-worker buffers with `aligned_alloc`,
  adds 64 bytes of slack, and passes `sap+ raw 64` as the usable buffer.
  This allows workers to store one byte *before* the block (for look-behind)
  without buffer underflow.
- **Exports** — routines are exported from `sb-posix` so callers can use the
  `sb-posix:` package prefix uniformly.

## SIMD package namespaces

`src/packages.cl` uses `:local-nicknames` rather than `:use`:

```lisp
(defpackage #:wordcount
  (:use #:cl #:with-user-abort #+avx2 #:sb-simd-avx2)
  (:shadow #:debug)
  (:local-nicknames #+avx2 (#:avx2    #:sb-simd-avx2)
                    #+avx2 (#:avx    #:sb-simd-avx)
                    #+avx2 (#:sse4.1 #:sb-simd-sse4.1)
                    #+avx512 (#:avx512bw #:sb-simd-avx512bw)
                    #+avx512 (#:avx512f  #:sb-simd-avx512f))
  ...)
```

Reason: `sb-simd-avx512bw` and `sb-simd-avx512f` export names (`U8!`,
`U64!`, ...) that `sb-simd-avx2` already inherits from `sb-simd-avx`.
`:use`-ing both packages directly signals a `NAME-CONFLICT` at package
creation. Local nicknames provide concise prefixes (`avx512bw:u8.64`,
`sse4.1:u64.2-elt`, ...) without namespace pollution.

`(:shadow #:debug)` is needed because the `cli-config` structure defines a
`debug` slot, colliding with `cl:debug` if not shadowed.

## `sb-thread` primitives

The worker pool in `src/scheduler.cl` uses:

- `sb-thread:make-thread` for OS thread creation.
- `sb-thread:make-semaphore`, `signal-semaphore`, `wait-on-semaphore` for
  worker coordination.
- `sb-thread:make-mutex` and `sb-thread:with-mutex` for pool lifecycle
  locking (`*pool-lock*`).
- `sb-thread:join-thread` on pool shutdown.

Worker 0 always runs on the calling thread; the worker pool creates
`nthreads - 1` background threads.

## Foreign memory

Three rules apply to every buffer used by the kernels:

1. **64-byte alignment.** AVX-512 vector operations and cache lines expect
   64-byte alignment. Buffers are allocated with `aligned_alloc(64, ...)`.
2. **64 bytes of slack.** Each worker stores one byte before its block
   (`sap+ buf-sap -1`) so that `init-ws` / `init-ed` can be derived from the
   preceding block's last byte. Allocations are rounded up with
   `round-up-64(chunk-size + 64)`, and the usable buffer pointer is `raw + 64`.
3. **Explicit free.** `sb-posix:alien-free` is called in `shutdown-worker-pool`
   for each worker buffer.

## The AVX-512 evec encoder requirement

The AVX-512 kernels use `sb-simd-avx512bw:u8.64` and related vector types.
In stock SBCL, `sb-simd`'s AVX-512 support is incomplete:

- The compiler-side instruction-set additions (`mask8.64`, `u8.64-mask=`,
  `u8.64-mask>=`, `mask64-bits`, etc.) are present in SBCL master.
- The **`evec` encoder** — the subsystem of sb-simd's IR that emits
  `avx512bw:u8.64-...` machine instructions — is not in stock SBCL. The author
  maintains a compiler branch that includes it.

If built against stock SBCL, `#+avx512` is not enabled, and the system
automatically compiles and runs with AVX2 or generic fallbacks.

## Build determinism

The resulting binary is **hardware-specific**:

- The `#+avx2` / `#+avx512` reader conditionals bake kernel availability into
  the compiled fasl files.
- `resolve-implementation` returns `:avx512` (on an AVX-512 build) for
  `:auto` without runtime CPUID queries.
- `kernel-call` macro-expands to concrete kernel function names at compile
  time.

Running an AVX-512 binary on a non-AVX-512 CPU will result in a `SIGILL`.
To produce a portable binary for any x86-64 machine, build with `WC_NO_SIMD=1`.

## Summary of the SBCL-only surface

| Feature                       | Where it is used                              | Portability |
|-------------------------------|-----------------------------------------------|-------------|
| `sb-sys:sap-*`, `sap+`        | All kernels, scheduler                        | SBCL-only   |
| `sb-sys:with-pinned-objects`  | Tests and user code calling SAP tier          | SBCL-only   |
| `sb-ext:defglobal`            | `kernels/common.cl`, `scheduler.cl`           | SBCL-only   |
| `sb-impl:+internal-features+` | `wordcount.asd`, `test-avx512-kernels.lisp`   | SBCL-only   |
| `sb-c:defknown`               | `common.cl`                                   | SBCL-only, version-sensitive |
| `sb-vm:define-vop`            | `common.cl`                                   | SBCL-only, version-sensitive |
| `sb-posix:define-call`        | `common.cl` (`posix_fadvise`)                 | SBCL-only   |
| `sb-posix:define-alien-routine` | `common.cl` (`sysconf`, `read`, `pread`, `aligned_alloc`, `free`) | SBCL-only |
| `sb-thread:*`                 | `scheduler.cl`                                | SBCL-only   |
| `sb-simd-avx2:*`              | All AVX2 kernels                              | Requires `sb-simd` |
| `sb-simd-avx512bw:*`, `sb-simd-avx512f:*` | All AVX-512 kernels             | Requires author's SBCL branch |
| `sb-alien:long`               | `common.cl`                                   | SBCL-only   |
| `sb-ext:*posix-argv*`         | `main.cl`                                     | SBCL-only   |
| `sb-ext:exit`                 | `main.cl`, `cli-options.cl`                   | SBCL-only   |
| `sb-int:strerror`             | `wc-driver.cl`                                | SBCL-only   |
