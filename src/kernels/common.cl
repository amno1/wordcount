;;; kernels/common.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Shared SIMD and SWAR kernel helpers for AVX2, AVX-512, and Generic backends.

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))


;;; Generic SWAR helpers

(defmacro gen-swar-kernel (sap size clines cwords cchars utf8 &optional (init-ws #xFF) (init-ed 0))
  (let* ((strict-p (and utf8 (or (eq utf8 'strict)
                                 (and (consp utf8)
                                      (or (eq (car utf8) 'quote) (eq (car utf8) 'function))
                                      (eq (cadr utf8) 'strict)))))
         (loop-end (gensym "LOOP-END"))
         (i (gensym "I"))
         (c (gensym "C"))
         (j (gensym "J"))
         (b (gensym "B"))
         (prev (gensym "PREV"))
         (prev-ws (gensym "PREV-WS"))
         (prev-ed (gensym "PREV-ED")))
    `(let* ((,loop-end (logandc2 ,size 7))
            ,@(when clines `((lines 0)))
            ,@(when cwords `((words 0)))
            ,@(when cchars `((chars ,(if (not utf8) size 0))))
            (,prev (logand ,init-ws #x80))
            (,prev-ed (if (zerop ,init-ed) 0 #x80)))
       (declare (type fixnum ,loop-end
                             ,@(when clines `(lines))
                             ,@(when cwords `(words))
                             ,@(when cchars `(chars)))
                (type (unsigned-byte 8) ,prev ,prev-ed)
                (ignorable ,prev ,prev-ed))

       ;; 1. Branchless 8-byte SWAR loop
       (loop for ,i of-type fixnum from 0 below ,loop-end by 8
             for ,c of-type (unsigned-byte 64) = (sb-sys:sap-ref-64 ,sap ,i)
             do
             ,@(when clines
                 `((incf lines (swar:new-line-count ,c))))
             ,@(when cwords
                 `((let ((curr (swar:gen-white-space-mask ,c)))
                     (declare (type (unsigned-byte 64) curr))
                     (incf words (swar:word-crossing-count curr ,prev))
                     (setf ,prev (logand (ash curr -56) #x80)))))
             ,@(when (and cchars utf8)
                 (if strict-p
                     `((multiple-value-bind (c-count new-ed)
                           (swar:utf8-count-strict ,c ,prev-ed)
                         (incf chars c-count)
                         (setf ,prev-ed new-ed)))
                     `((incf chars (swar:utf8-count-fast ,c))))))

       ;; 2. Scalar tail for remaining 0 to 7 bytes
       (when (> ,size ,loop-end)
         (let (,@(when cwords `((,prev-ws (not (zerop ,prev)))))
               ,@(when (and cchars strict-p) `((,prev-ed (not (zerop ,prev-ed))))))
           ,@(when cwords `((declare (type boolean ,prev-ws))))
           ,@(when (and cchars strict-p) `((declare (type boolean ,prev-ed))))
           (loop for ,j of-type fixnum from ,loop-end below ,size
                 for ,b of-type (unsigned-byte 8) = (sb-sys:sap-ref-8 ,sap ,j)
                 do
                 ,@(when clines
                     `((when (= ,b 10) (incf lines))))
                 ,@(when cwords
                     `((let ((curr (or (= ,b 32) (<= 9 ,b 13))))
                         (when (and ,prev-ws (not curr)) (incf words))
                         (setf ,prev-ws curr))))
                 ,@(when (and cchars utf8)
                     (if strict-p
                         `((let ((ascii (<= ,b 127))
                                 (vlead (<= 194 ,b 244))
                                 (bad (and ,prev-ed (<= #xA0 ,b #xBF))))
                             (when (and (or ascii vlead) (not bad))
                               (incf chars))
                             (setf ,prev-ed (= ,b #xED))))
                         `((unless (= (logand ,b #xC0) #x80)
                             (incf chars))))))))

       (values ,(if clines 'lines 'nil)
               ,(if cwords 'words 'nil)
               ,(if cchars 'chars 'nil)))))

(defmacro def-swar-kernel (name (&rest args) &key lines words chars utf8)
  (let ((ws-arg (if (member 'ws-init-state args) 'ws-init-state #xFF))
        (ed-arg (if (or (member 'ed-init-state args) (member '&optional args)) 'ed-init-state 0)))
    `(defun ,name ,args
       (declare (type sb-sys:system-area-pointer sap)
                (type fixnum size)
                ,@(when (member 'ws-init-state args)
                    `((type (unsigned-byte 8) ws-init-state)))
                ,@(when (or (member 'ed-init-state args) (member '&optional args))
                    `((type (unsigned-byte 8) ed-init-state)))
                (optimize (speed 3) (safety 0)))
       (gen-swar-kernel sap size ,lines ,words ,chars ,utf8 ,ws-arg ,ed-arg))))


;;; AVX2 helpers

#+avx2
(progn
  (declaim (inline sum-lanes))
  (defun sum-lanes (acc)
    (declare (type u64.4 acc))
    (let* ((lo (u64.2-from-u64.4 acc 0))
           (hi (u64.2-from-u64.4 acc 1))
           (sum (u64.2+ lo hi))
           (max most-positive-fixnum))
      (declare (type u64.2 lo hi sum))
      (the fixnum
           (truncate
            (+ (logand (sse4.1:u64.2-elt sum 0) max)
               (logand (sse4.1:u64.2-elt sum 1) max))
            255)))))


;;; AVX-512 helpers

#+avx512
(progn
  (declaim (inline mask64-bits))
  (defun mask64-bits (m)
    (declare (type avx512bw:m8.64 m)
             (optimize (speed 3) (safety 0))
             (sb-ext:muffle-conditions sb-ext:compiler-note))
    (the (unsigned-byte 64) (avx512bw:m8.64-value m)))

  (declaim (inline popcount64))
  (defun popcount64 (m)
    (declare (type (unsigned-byte 64) m)
             (optimize (speed 3) (safety 0)))
    (the (unsigned-byte 64) (wc::fpopcount m)))

  (sb-ext:defglobal +ws-lut+
    (avx512bw:u8.64!
     (sb-ext:%make-simd-pack-512-ub64
      #x20 #x0d0c0b0a0900
      #x20 #x0d0c0b0a0900
      #x20 #x0d0c0b0a0900
      #x20 #x0d0c0b0a0900)))

  (sb-ext:defglobal +lf-vec+
    (avx512bw:u8.64 10))

  (sb-ext:defglobal +cont-c0+
    (avx512bw:u8.64 #xC0))

  (sb-ext:defglobal +cont-80+
    (avx512bw:u8.64 #x80))

  (sb-ext:defglobal +utf8-v80+  (avx512bw:u8.64 #x80))
  (sb-ext:defglobal +utf8-v0+   (avx512bw:u8.64 0))
  (sb-ext:defglobal +utf8-v194+ (avx512bw:u8.64 194))
  (sb-ext:defglobal +utf8-v244+ (avx512bw:u8.64 244))
  (sb-ext:defglobal +utf8-ved+  (avx512bw:u8.64 #xED))
  (sb-ext:defglobal +utf8-va0+  (avx512bw:u8.64 #xA0))
  (sb-ext:defglobal +utf8-vbf+  (avx512bw:u8.64 #xBF))

  (declaim (inline ws-bits-512))
  (defun ws-bits-512 (chunk ws-lut)
    (declare (type avx512bw:u8.64 chunk ws-lut)
             (optimize (speed 3) (safety 0))
             (sb-ext:muffle-conditions sb-ext:compiler-note))
    (mask64-bits
     (avx512bw:u8.64-mask=
      (avx512bw:u8.64-shuffle ws-lut chunk)
      chunk)))

  (declaim (inline line-bits-512))
  (defun line-bits-512 (chunk lf-vec)
    (declare (type avx512bw:u8.64 chunk lf-vec)
             (optimize (speed 3) (safety 0))
             (sb-ext:muffle-conditions sb-ext:compiler-note))
    (mask64-bits (avx512bw:u8.64-mask= chunk lf-vec)))

  (declaim (inline cont-bits-512))
  (defun cont-bits-512 (chunk c0-vec 80-vec)
    (declare (type avx512bw:u8.64 chunk c0-vec 80-vec)
             (optimize (speed 3) (safety 0))
             (sb-ext:muffle-conditions sb-ext:compiler-note))
    (mask64-bits
     (avx512bw:u8.64-mask=
      (avx512bw:u8.64-and chunk c0-vec)
      80-vec)))

  (declaim (inline utf8-strict-bits-512))
  (defun utf8-strict-bits-512 (chunk prev-was-ed v80 v0 v194 v244 ved va0 vbf)
    (declare (type avx512bw:u8.64 chunk v80 v0 v194 v244 ved va0 vbf)
             (type (unsigned-byte 64) prev-was-ed)
             (optimize (speed 3) (safety 0))
             (sb-ext:muffle-conditions sb-ext:compiler-note))
    (let* ((ascii-bits (mask64-bits
                        (avx512bw:u8.64-mask=
                         (avx512bw:u8.64-and chunk v80)
                         v0)))
           (vlead-bits (mask64-bits
                        (avx512bw:m8.64-and
                         (avx512bw:u8.64-mask>= chunk v194)
                         (avx512bw:u8.64-mask<= chunk v244))))
           (ed-bits    (mask64-bits
                        (avx512bw:u8.64-mask= chunk ved)))
           (ed-shift   (logior (ldb (byte 64 0) (ash ed-bits 1)) prev-was-ed))
           (foll-bits  (mask64-bits
                        (avx512bw:m8.64-and
                         (avx512bw:u8.64-mask>= chunk va0)
                         (avx512bw:u8.64-mask<= chunk vbf))))
           (bad-bits   (logand ed-shift foll-bits))
           (valid-bits (logandc2 (logior ascii-bits vlead-bits) bad-bits)))
      (declare (type (unsigned-byte 64)
                     ascii-bits vlead-bits ed-bits ed-shift foll-bits bad-bits valid-bits))
      (values valid-bits ed-bits))))

;;; kernels/common.cl ends here
