;;; test-simd-constant-reload.lisp
;;;
;;; Standalone reproducer demonstrating that SBCL fails to hoist SIMD vector
;;; constants out of loops when bound with LET or LOAD-TIME-VALUE, causing
;;; redundant memory reloads from the code constant pool on every iteration.
;;;
;;; Run with: sbcl --noinform --load test-simd-constant-reload.lisp

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

(format t "~%================================================================~%")
(format t "CASE 1: LET with literal (u8.32 10)~%")
(format t "Notice: 4 x VMOVDQU YMM1, [RIP-disp] INSIDE the loop body~%")
(format t "================================================================~%")
(disassemble 'test-literal)

(format t "~%================================================================~%")
(format t "CASE 2: LET with (load-time-value (u8.32 10))~%")
(format t "Notice: 4 x VMOVDQU YMM1, [RIP-disp] INSIDE the loop body~%")
(format t "================================================================~%")
(disassemble 'test-load-time-value)

(format t "~%================================================================~%")
(format t "CASE 3: LET with DEFGLOBAL (*g-vec*)~%")
(format t "Notice: VMOVDQU YMM1 loaded ONCE BEFORE loop entry; 0 reloads inside:~%")
(format t "================================================================~%")
(disassemble 'test-defglobal)

(sb-ext:exit :code 0)
