;;; kernels/common.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Shared SIMD and SWAR kernel helpers for AVX2, AVX-512, and Generic backends.

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))


;;; Generic SWAR helpers

(declaim (inline %generic-ws-p))
(defun %generic-ws-p (byte)
  (declare (type (unsigned-byte 8) byte) (optimize (speed 3) (safety 0)))
  (or (= byte 32) (<= 9 byte 13)))

(declaim (inline swar-byte))
;; Byte K (0 = least significant) of 8-byte CHUNK.
(defun swar-byte (chunk k)
  (declare (type (unsigned-byte 64) chunk) (type (integer 0 7) k)
           (optimize (speed 3) (safety 0)))
  (ldb (byte 8 (* k 8)) chunk))

;; Bind BYTE-VAR to each of CHUNK's 8 bytes in turn, accumulating bit 7
;; of that lane into MASK-VAR (already bound) whenever BODY is true.
(defmacro do-chunk-bytes ((byte-var chunk mask-var) &body body)
  (let ((k (gensym "K")))
    `(dotimes (,k 8 ,mask-var)
       (let ((,byte-var (swar-byte ,chunk ,k)))
         (when (progn ,@body)
           (setf ,mask-var (logior ,mask-var (ash #x80 (* ,k 8)))))))))

(declaim (inline swar-newline-mask))
;; Bit 7 of each byte lane set iff that byte is #\Newline (10).
(defun swar-newline-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (= byte 10))))

(declaim (inline swar-ws-mask))
;; Bit 7 of each byte lane set iff that byte is ASCII whitespace
;; (space, or in [9,13]).
(defun swar-ws-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (%generic-ws-p byte))))

(declaim (inline swar-word-starts))
;; Count of word-start transitions (whitespace -> non-whitespace)
;; within WS-MASK. PREV-HIGH-BIT carries the previous chunk's last
;; byte's whitespace bit (0 or #x80) into byte 0's position.
(defun swar-word-starts (ws-mask prev-high-bit)
  (declare (type (unsigned-byte 64) ws-mask) (type (unsigned-byte 8) prev-high-bit)
           (optimize (speed 3) (safety 0)))
  (let* ((shifted (logior (ldb (byte 64 0) (ash ws-mask 8)) prev-high-bit))
         (transitions (logand shifted (lognot ws-mask) #x8080808080808080)))
    (declare (type (unsigned-byte 64) shifted transitions))
    (the fixnum (logcount transitions))))

(declaim (inline swar-chunk-carry))
;; Extract byte 7's high bit from MASK (0 or #x80), to seed the next chunk's carry.
(defun swar-chunk-carry (mask)
  (declare (type (unsigned-byte 64) mask) (optimize (speed 3) (safety 0)))
  (ldb (byte 8 0) (ash mask -56)))

(declaim (inline swar-utf8-count-fast))
;; Fast UTF-8 char start count in 8-byte chunk.
(defun swar-utf8-count-fast (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0)))
  (let* ((shifted (ldb (byte 64 0) (ash chunk 1)))
         (cont-mask (logand chunk (lognot shifted) #x8080808080808080)))
    (declare (type (unsigned-byte 64) shifted cont-mask))
    (the fixnum (- 8 (logcount cont-mask)))))

(declaim (inline swar-utf8-valid-lead-mask))
;; Bit 7 of each byte lane set iff byte is ASCII (<=0x7F) or valid lead (0xC2-0xF4).
(defun swar-utf8-valid-lead-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (or (<= byte #x7F) (<= #xC2 byte #xF4)))))

(declaim (inline swar-ed-mask))
;; Bit 7 of each byte lane set iff byte is 0xED.
(defun swar-ed-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (= byte #xED))))

(declaim (inline swar-bad-surrogate-mask))
;; Bit 7 of each byte lane set iff that byte is an A0-BF follow-up to an
;; immediately preceding 0xED lead. Second value is the new carry.
(defun swar-bad-surrogate-mask (chunk prev-ed-high-bit)
  (declare (type (unsigned-byte 64) chunk)
           (type (unsigned-byte 8) prev-ed-high-bit)
           (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let* ((ed-mask (swar-ed-mask chunk))
         (follow-mask 0)
         (ed-shifted (logior (ldb (byte 64 0) (ash ed-mask 8)) prev-ed-high-bit)))
    (declare (type (unsigned-byte 64) follow-mask ed-shifted))
    (setf follow-mask (do-chunk-bytes (byte chunk follow-mask) (<= #xA0 byte #xBF)))
    (values (logand ed-shifted follow-mask) (swar-chunk-carry ed-mask))))


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
