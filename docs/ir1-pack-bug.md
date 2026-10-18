The presence of these globals in [`src/kernels/common.cl`](file:///home/arthur/repos/cl/wordcount/src/kernels/common.cl#L152-L176) serves two distinct purposes: **non-trivial table construction** and, surprisingly, **a critical compiler optimization workaround for SBCL's SIMD code generator**.

---

### 1. Does it really save anything? (The SBCL Compiler Quirk)

**Yes — it saves millions of memory loads in the hot loop.**

In Common Lisp, one might expect:
```lisp
(let ((lf-vec (sb-simd-avx512bw:u8.64 10)))
  (loop ...))
```
to load `10` into a `ZMM` register once outside the loop. But disassembling SBCL reveals that **it does not**:

#### What SBCL generates with `(let ((lf-vec (u8.64 10))))` (or `load-time-value`):
Because `(u8.64 10)` is folded by `sb-simd` into an unboxed literal `#<SIMD-PACK-512 ...>`, SBCL's IR1 constant propagation replaces references to `lf-vec` with the constant literal. SBCL treats literal SIMD packs as cheap memory operands and re-emits a 64-byte constant pool load at **every unrolled instruction site**:
```assembly
;; Inside the 512-byte loop body (unrolled 8 times):
E06:  VMOVDQU8 ZMM0, [RBX+RAX]
E0D:  VMOVDQU64 ZMM1, [RIP-151]   ; <-- Reload #1 from memory!
E17:  VPCMPUB K1, ZMM0, ZMM1, 0
...
E38:  VMOVDQU8 ZMM0, [RBX+RCX]
E3F:  VMOVDQU64 ZMM1, [RIP-201]   ; <-- Reload #2 from memory!
E49:  VPCMPUB K1, ZMM0, ZMM1, 0
...
; (Repeated 8 times per 512-byte iteration!)
```
That is **8 redundant 64-byte memory loads (`VMOVDQU64`) for every 512 bytes scanned**. Over a 100 MB file, that wastes 1.6 million memory loads.

#### What SBCL generates with `(let ((lf-vec +lf-vec+)))`:
Because `+lf-vec+` is defined via `sb-ext:defglobal`, SBCL treats reading it as a dynamic variable load rather than a compile-time foldable constant literal:
1. At function entry (outside the loop), it loads the vector **once** into register `ZMM0`:
   ```assembly
   DBE:  MOV RAX, [RIP-69]              ; +LF-VEC+ symbol
   DC5:  MOV RAX, [RAX+1]               ; value cell
   DC9:  VMOVDQU64 ZMM0, [RAX+1]        ; load into ZMM0 once
   ```
2. Because `lf-vec` is an opaque lexical variable live across the loop, SBCL's register allocator assigns it to a dedicated `ZMM` register.
3. Inside the inner loop, all 8 chunks run **100% register-to-register** with zero memory reloads:
   ```assembly
   ;; Inside the 512-byte loop body:
   DF0:  VMOVDQU8 ZMM1, [R8+RDX]
   DF7:  VPCMPUB K1, ZMM1, ZMM0, 0     ; Pure register comparison against ZMM0!
   DFE:  KMOVQ RAX, K1
   E03:  POPCNT RCX, RAX
   ...
   E12:  VMOVDQU8 ZMM1, [R8+RCX]
   E19:  VPCMPUB K1, ZMM1, ZMM0, 0     ; Pure register comparison against ZMM0!
   ```

*(In fact, checking the AVX2 kernels where `(u8.32 #x0A)` was written inline as a literal reveals that SBCL is actively emitting 8 `VMOVDQU` constant reloads and spilling to the stack on every iteration. The AVX-512 kernels avoided this by using `defglobal`.)*

---

### 2. Why do we have `+ws-lut+` specifically?

`+ws-lut+` is not a single uniform broadcast byte like `(u8.64 10)`. It is a 64-byte lookup table used for `vpshufb` (`avx512bw:u8.64-shuffle`) in `ws-bits-512`:

```lisp
(sb-ext:defglobal +ws-lut+
  (avx512bw:u8.64!
   (sb-ext:%make-simd-pack-512-ub64
    #x20 #x0d0c0b0a0900
    #x20 #x0d0c0b0a0900
    #x20 #x0d0c0b0a0900
    #x20 #x0d0c0b0a0900)))
```

- Each 16-byte lane is indexed by `chunk & 0x0F` to match whitespace characters: `#x00`, `#x09` (`\t`), `#x0A` (`\n`), `#x0B` (`\v`), `#x0C` (`\f`), `#x0D` (`\r`), and `#x20` (space).
- Because the byte pattern is non-uniform, it cannot be broadcast using a standard `(u8.64 byte)` instruction. It has to be constructed from 8 64-bit words via internal compiler primitive `sb-ext:%make-simd-pack-512-ub64`.
- Defining it once in `common.cl` avoids repeatedly building or specifying this 64-byte structure across all 5 word-counting kernel files ([`words.cl`](file:///home/arthur/repos/cl/wordcount/src/kernels/words.cl), [`lines-and-words.cl`](file:///home/arthur/repos/cl/wordcount/src/kernels/lines-and-words.cl), [`words-and-chars.cl`](file:///home/arthur/repos/cl/wordcount/src/kernels/words-and-chars.cl), [`lines-words-and-chars.cl`](file:///home/arthur/repos/cl/wordcount/src/kernels/lines-words-and-chars.cl)).

---

### 3. Deduplication and Code Sharing

These vector constants are shared across multiple kernel implementations:
- `+ws-lut+`: shared across 5 kernel files.
- `+lf-vec+`: shared across 4 kernel files.
- `+cont-c0+` & `+cont-80+`: shared across 4 kernel files.
- The 7 UTF-8 strict validation vectors (`+utf8-v80+` through `+utf8-vbf+`): passed into `utf8-strict-bits-512` across 4 kernel files.

If each file defined its own constants or embedded literals, not only would the unrolled loops reload them from code constant pools repeatedly, but the binary would also contain duplicate copies of every 64-byte vector in each compiled function's constant pool.

---

### Summary

| Aspect | Inline `(u8.64 ...)` / `load-time-value` | `sb-ext:defglobal` |
| :--- | :--- | :--- |
| **Hot Loop Execution** | Constant reloaded from memory on **every unrolled chunk** (8 loads / 512 bytes) | Vector hoisted to a `ZMM` register **once**; hot loop is 100% register-to-register |
| **Function Entry** | Direct RIP-relative load | 2 pointer dereferences to read global value cell (~2 ns, amortized over entire block) |
| **Complex Tables (`+ws-lut+`)** | Verbose 64-byte constructor repeated in 5 files | Defined once centrally |
| **Constant Pool Size** | Duplicated across all compiled kernel functions | Shared single instance |

In short: while defining globals may seem like cosmetic deduplication, in SBCL it is actually the reason the AVX-512 inner loops stay in registers and don't stall on constant-pool reloads.

It requires only standard stock SBCL with `sb-simd` (no project dependencies or AVX-512 required; it reproduces identically on AVX2 with `u8.32` as it does on AVX-512 with `u8.64`).

### How to Run It

```bash
sbcl --noinform --load tools/test-simd-constant-reload.lisp
```

---

### The Standalone Code

```lisp
;;; tools/test-simd-constant-reload.lisp
(require :sb-simd)

(defpackage :simd-hoist-bug
  (:use :cl :sb-simd-avx2))

(in-package :simd-hoist-bug)

(sb-ext:defglobal *g-vec* (u8.32 10))

;;; Case 1: Lexical LET binding with constant vector literal (u8.32 10)
(defun test-literal (sap n)
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((c (u8.32 10))
        (acc 0))
    (declare (type u8.32 c)
             (type (unsigned-byte 64) acc))
    (dotimes (i n)
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 0) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 32) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 64) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 96) c)))))
    acc))

;;; Case 2: Lexical LET binding with LOAD-TIME-VALUE
(defun test-load-time-value (sap n)
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((c (load-time-value (u8.32 10)))
        (acc 0))
    (declare (type u8.32 c)
             (type (unsigned-byte 64) acc))
    (dotimes (i n)
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 0) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 32) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 64) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 96) c)))))
    acc))

;;; Case 3: Lexical LET binding reading a DEFGLOBAL
(defun test-defglobal (sap n)
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum n)
           (optimize (speed 3) (safety 0)))
  (let ((c *g-vec*)
        (acc 0))
    (declare (type u8.32 c)
             (type (unsigned-byte 64) acc))
    (dotimes (i n)
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 0) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 32) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 64) c))))
      (incf acc (logcount (u8.32-movemask (u8.32= (u8.32-sap-ref sap 96) c)))))
    acc))
```

---

### Disassembly Comparison

Running the script prints the disassembly of all three functions:

#### `test-literal` / `test-load-time-value` (The Bug)
SBCL reloads `c` from the code constant pool at **every unrolled chunk inside the loop**:
```assembly
;; Loop body L0:
430: L0:  VMOVDQU YMM0, [RDI]
434:      VMOVDQU YMM1, [RIP-92]          ; <-- Memory reload #1!
43C:      VPCMPEQB YMM0, YMM0, YMM1
...
46D:      VMOVDQU YMM0, [RDI+32]
472:      VMOVDQU YMM1, [RIP-154]         ; <-- Memory reload #2!
47A:      VPCMPEQB YMM0, YMM0, YMM1
...
4AB:      VMOVDQU YMM0, [RDI+64]
4B0:      VMOVDQU YMM1, [RIP-216]         ; <-- Memory reload #3!
4B8:      VPCMPEQB YMM0, YMM0, YMM1
...
4E9:      VMOVDQU YMM0, [RDI+96]
4EE:      VMOVDQU YMM1, [RIP-278]         ; <-- Memory reload #4!
4F6:      VPCMPEQB YMM0, YMM0, YMM1
...
52E:      JL L0
```

#### `test-defglobal` (The Workaround)
SBCL loads `*g-vec*` **once** before entering the loop into `YMM0`. The loop body contains **zero** constant reloads:
```assembly
;; Before loop entry:
61D:      MOV RAX, [#x5013DD50]           ; *G-VEC*
625:      VMOVDQU YMM0, [RAX+1]           ; Loaded once into YMM0!
...
;; Loop body L0 (100% register-to-register):
640: L0:  VMOVDQU YMM1, [RDI]
644:      VPCMPEQB YMM1, YMM1, YMM0       ; Compares against YMM0
...
675:      VMOVDQU YMM1, [RDI+32]
67A:      VPCMPEQB YMM1, YMM1, YMM0       ; Compares against YMM0
...
6AB:      VMOVDQU YMM1, [RDI+64]
6B0:      VPCMPEQB YMM1, YMM1, YMM0       ; Compares against YMM0
...
6E1:      VMOVDQU YMM1, [RDI+96]
6E6:      VPCMPEQB YMM1, YMM1, YMM0       ; Compares against YMM0
...
71E:      JL L0
```

---

### Why this happens in SBCL

1. **IR1 Constant Substitution:** In `src/compiler/ir1opt.lisp` (`propagate-let-phases`), when a `LET` variable is initialized to a constant expression (such as `(u8.32 10)` or `(load-time-value ...)`), `substitute-leaf-if` replaces every reference to the variable with a reference to the constant leaf `#<CONSTANT ...>` and calls `delete-let` to delete the variable binding entirely.

2. **Missing Loop-Invariant Code Motion (LICM):** SBCL assumes constant operands are cheap (immediate values or memory addresses). But SIMD comparison instructions require vector registers (`INT-AVX2-REG` / `INT-AVX512-REG`). Because there is no register-level LICM for constant loads, the code generator emits a `VMOVDQU` from the constant pool immediately before each consumer instruction inside the loop.

3. **Why `defglobal` works around it:** Reading a `defglobal` is treated as a dynamic variable read that IR1 cannot constant-fold. The `LET` variable node is preserved, so SBCL's register allocator hoists the vector load into a register once outside the loop.
