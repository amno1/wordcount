;;; kernels/lines.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Line counting kernels (Generic, AVX2, AVX-512).

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))

(declaim (inline count-lines-generic count-lines-ascii-generic count-lines-utf8-generic
                 count-lines-avx2 count-lines-ascii count-lines-utf8
                 #+avx512 count-lines-512
                 #+avx512 count-lines-avx512
                 #+avx512 count-lines-ascii-avx512
                 #+avx512 count-lines-utf8-avx512))


;;; Generic SWAR implementation

(defun count-lines-generic (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 7))
        (lines 0))
    (declare (type fixnum loop-end lines))
    (loop for i of-type fixnum from 0 below loop-end by 8
          do (incf lines (logcount (swar-newline-mask (sb-sys:sap-ref-64 sap i)))))
    (loop for j of-type fixnum from loop-end below size
          when (= (sb-sys:sap-ref-8 sap j) 10) do (incf lines))
    (values lines nil nil)))

(defun count-lines-ascii-generic (sap size)
  (count-lines-generic sap size))

(defun count-lines-utf8-generic (sap size)
  (count-lines-generic sap size))


;;; AVX2 implementation

(defun count-lines-avx2 (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (loop
    with loop-end of-type fixnum = (logandc2 size 255)
    for i of-type fixnum from 0 below loop-end by 256
    with 0x0A of-type u8.32 = (u8.32 #x0A)
    with 0x0  of-type u8.32 = (u8.32 #x00)
    with a1 of-type u64.4 = (u64.4 0)
    with a2 of-type u64.4 = (u64.4 0)
    with a3 of-type u64.4 = (u64.4 0)
    with a4 of-type u64.4 = (u64.4 0)
    with a5 of-type u64.4 = (u64.4 0)
    with a6 of-type u64.4 = (u64.4 0)
    with a7 of-type u64.4 = (u64.4 0)
    with a8 of-type u64.4 = (u64.4 0)

    for c1 of-type u8.32 = (u8.32-sap-ref sap (+ i 0))
    for c2 of-type u8.32 = (u8.32-sap-ref sap (+ i 32))
    for c3 of-type u8.32 = (u8.32-sap-ref sap (+ i 64))
    for c4 of-type u8.32 = (u8.32-sap-ref sap (+ i 96))
    for c5 of-type u8.32 = (u8.32-sap-ref sap (+ i 128))
    for c6 of-type u8.32 = (u8.32-sap-ref sap (+ i 160))
    for c7 of-type u8.32 = (u8.32-sap-ref sap (+ i 192))
    for c8 of-type u8.32 = (u8.32-sap-ref sap (+ i 224))
    do
       (setf a1 (u64.4+ a1 (u8.32-sad (u8.32= c1 0x0A) 0x0)))
       (setf a2 (u64.4+ a2 (u8.32-sad (u8.32= c2 0x0A) 0x0)))
       (setf a3 (u64.4+ a3 (u8.32-sad (u8.32= c3 0x0A) 0x0)))
       (setf a4 (u64.4+ a4 (u8.32-sad (u8.32= c4 0x0A) 0x0)))
       (setf a5 (u64.4+ a5 (u8.32-sad (u8.32= c5 0x0A) 0x0)))
       (setf a6 (u64.4+ a6 (u8.32-sad (u8.32= c6 0x0A) 0x0)))
       (setf a7 (u64.4+ a7 (u8.32-sad (u8.32= c7 0x0A) 0x0)))
       (setf a8 (u64.4+ a8 (u8.32-sad (u8.32= c8 0x0A) 0x0)))
    finally
       (let* ((sum (u64.4+ a1 a2 a3 a4 a5 a6 a7 a8))
              (lines (sum-lanes sum))
              (tail  (loop for j from loop-end below size
                           count (= (sb-sys:sap-ref-8 sap j) 10))))
         (declare (type fixnum lines tail))
         (return (values (the fixnum (+ lines tail)) nil nil)))))

(defun count-lines-ascii (sap size)
  (count-lines-avx2 sap size))

(defun count-lines-utf8 (sap size)
  (count-lines-avx2 sap size))


;;; AVX-512 implementation

#+avx512
(progn
  (defun count-lines-512 (sap size)
    (declare (type fixnum size)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (lf-vec +lf-vec+)
          (la0 0) (la1 0) (la2 0) (la3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 lf-vec)
               (type (unsigned-byte 64) la0 la1 la2 la3))
      (macrolet ((chunk (offset la)
                   `(incf ,la (popcount64
                               (line-bits-512
                                (avx512bw:u8.64-sap-ref sap (+ i ,offset))
                                lf-vec)))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   la0)
          (chunk 64  la1)
          (chunk 128 la2)
          (chunk 192 la3)
          (chunk 256 la0)
          (chunk 320 la1)
          (chunk 384 la2)
          (chunk 448 la3)))
      (let ((lines (+ la0 la1 la2 la3)))
        (declare (type (unsigned-byte 64) lines))
        (loop for j of-type fixnum from loop-end below size
              when (= (sb-sys:sap-ref-8 sap j) 10) do (incf lines))
        (values (the fixnum lines) nil nil))))

  (defun count-lines-avx512 (sap size)
    (count-lines-512 sap size))

  (defun count-lines-ascii-avx512 (sap size)
    (count-lines-512 sap size))

  (defun count-lines-utf8-avx512 (sap size)
    (count-lines-512 sap size)))

;;; kernels/lines.cl ends here
