;;; kernels-avx512.cl
;; Copyright (C) 2026  Arthur Miller

;; Author: Arthur Miller <arthur.miller@live.com>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; AVX-512BW version of kernels-avx2.cl. Every kernel works on
;; 64-byte chunks (U8.64), classifies bytes by comparing into a
;; k-register (VPCMPUB), pulls the 64-bit mask out with a single KMOVQ
;; (MASK64-BITS), and folds it with a bare POPCNT (POPCOUNT64).
;;
;; Choices made:
;;   * Whitespace classification uses VPSHUFB (U8.64-SHUFFLE) with a
;;     lookup table and VPCMPUB, compiling to only 2 instructions instead
;;     of 3 comparisons and 2 mask operations.
;;   * All vector constants (+WS-LUT+, +LF-VEC+, etc.) are hoisted to ZMM
;;     registers outside the inner loops, eliminating redundant loads.
;;   * POPCOUNT64 operates directly on unboxed 64-bit registers without
;;     fixnum tagging overhead.
;;   * Accumulators use 64-bit unboxed registers in the hot loop.

;;; Code:
#-sbcl
(error "This file requires SBCL compiler.")
#-avx512
(error "This file requires an SBCL/sb-simd build with AVX-512 support.")

(declaim (optimize (speed 3) (safety 0)))

(in-package :wc)

(declaim (inline count-lines-words-and-chars-utf8-avx512
                 count-lines-words-and-chars-ascii-avx512
                 count-lines-words-and-chars-utf8-strict-avx512
                 count-lines-utf8-avx512 count-words-utf8-avx512 count-chars-utf8-avx512
                 count-lines-ascii-avx512 count-words-ascii-avx512 count-chars-ascii-avx512
                 count-lines-and-words-utf8-avx512 count-words-and-chars-utf8-avx512
                 count-lines-and-chars-utf8-avx512 count-lines-and-chars-utf8-strict-avx512
                 count-words-and-chars-utf8-strict-avx512
                 count-lines-and-words-ascii-avx512 count-words-and-chars-ascii-avx512
                 count-lines-and-chars-ascii-avx512
                 count-chars-utf8-strict-avx512))


;;; helpers

;;; Extract the 64-bit mask from an M8.64 k-register value.
(declaim (inline mask64-bits))
(defun mask64-bits (m)
  (declare (type avx512bw:m8.64 m)
           (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (the (unsigned-byte 64) (avx512bw:m8.64-value m)))

;;; Bare POPCNT returning unboxed 64-bit unsigned integer.
(declaim (inline popcount64))
(defun popcount64 (m)
  (declare (type (unsigned-byte 64) m)
           (optimize (speed 3) (safety 0)))
  (the (unsigned-byte 64) (wc::fpopcount m)))

(declaim (inline sum-lanes-512))
;; Reduce a U64.8 accumulator to a fixnum.
(defun sum-lanes-512 (acc)
  (declare (type avx512f:u64.8 acc)
           (optimize (speed 3) (safety 0)))
  (let* ((sum4 (u64.4+ (avx512f:u64.4-from-u64.8 acc 0)
                        (avx512f:u64.4-from-u64.8 acc 1)))
         (lo (u64.2-from-u64.4 sum4 0))
         (hi (u64.2-from-u64.4 sum4 1))
         (sum (u64.2+ lo hi))
         (max most-positive-fixnum))
    (declare (type u64.4 sum4) (type u64.2 lo hi sum))
    (the fixnum
         (+ (logand (sse4.1:u64.2-elt sum 0) max)
            (logand (sse4.1:u64.2-elt sum 1) max)))))

;;; Hoisted Vector Constants
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
;; Bit N set iff byte N of CHUNK is ASCII whitespace (VPSHUFB lookup).
(defun ws-bits-512 (chunk ws-lut)
  (declare (type avx512bw:u8.64 chunk ws-lut)
           (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (mask64-bits
   (avx512bw:u8.64-mask=
    (avx512bw:u8.64-shuffle ws-lut chunk)
    chunk)))

(declaim (inline line-bits-512))
;; Bit N set iff byte N of CHUNK is \n.
(defun line-bits-512 (chunk lf-vec)
  (declare (type avx512bw:u8.64 chunk lf-vec)
           (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (mask64-bits (avx512bw:u8.64-mask= chunk lf-vec)))

(declaim (inline cont-bits-512))
;; Bit N set iff byte N of CHUNK is a UTF-8 continuation byte.
(defun cont-bits-512 (chunk c0-vec 80-vec)
  (declare (type avx512bw:u8.64 chunk c0-vec 80-vec)
           (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (mask64-bits
   (avx512bw:u8.64-mask=
    (avx512bw:u8.64-and chunk c0-vec)
    80-vec)))

(declaim (inline utf8-strict-bits-512))
;; Return (VALUES VALID ED) for strict UTF-8 start-byte classification.
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
    (values valid-bits ed-bits)))


;;; count lines

(declaim (inline count-lines-512))
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
    (macrolet ((chunk (offset)
                 `(popcount64
                   (line-bits-512
                    (avx512bw:u8.64-sap-ref sap (+ i ,offset))
                    lf-vec))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (incf la0 (+ (chunk 0)   (chunk 256)))
        (incf la1 (+ (chunk 64)  (chunk 320)))
        (incf la2 (+ (chunk 128) (chunk 384)))
        (incf la3 (+ (chunk 192) (chunk 448)))))
    (let ((lines (+ la0 la1 la2 la3)))
      (declare (type (unsigned-byte 64) lines))
      (loop for j of-type fixnum from loop-end below size
            when (= (sb-sys:sap-ref-8 sap j) 10)
              do (incf lines))
      (values (the fixnum lines) nil nil))))

(defun count-lines-utf8-avx512 (sap size)  (count-lines-512 sap size))
(defun count-lines-ascii-avx512 (sap size) (count-lines-512 sap size))


;;; count words

(declaim (inline count-words))
(defun count-words (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (ws-lut +ws-lut+)
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (wa0 0) (wa1 0) (wa2 0) (wa3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 ws-lut)
             (type (unsigned-byte 64) wa0 wa1 wa2 wa3 prev-was-ws))
    (macrolet ((chunk (offset wa)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c ws-lut))
                         (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask shifted starts))
                    (setf prev-was-ws (ash ws-mask -63))
                    (incf ,wa (popcount64 starts)))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   wa0)
        (chunk 64  wa1)
        (chunk 128 wa2)
        (chunk 192 wa3)
        (chunk 256 wa0)
        (chunk 320 wa1)
        (chunk 384 wa2)
        (chunk 448 wa3)))
    (let ((words (+ wa0 wa1 wa2 wa3)))
      (declare (type (unsigned-byte 64) words))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (setf prev-was-ws (if is-ws 1 0)))
      (values nil (the fixnum words) nil))))

(defun count-words-ascii-avx512 (sap size ws-init-state)
  (count-words sap size ws-init-state))
(defun count-words-utf8-avx512 (sap size ws-init-state)
  (count-words sap size ws-init-state))


;;; count chars

(defun count-chars-utf8-avx512 (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (c0-vec +cont-c0+)
        (80-vec +cont-80+)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 c0-vec 80-vec)
             (type (unsigned-byte 64) ca0 ca1 ca2 ca3))
    (macrolet ((chunk (offset)
                 `(popcount64
                   (logand #xFFFFFFFFFFFFFFFF
                           (lognot (cont-bits-512
                                    (avx512bw:u8.64-sap-ref
                                     sap (+ i ,offset))
                                    c0-vec 80-vec))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (incf ca0 (+ (chunk 0)   (chunk 256)))
        (incf ca1 (+ (chunk 64)  (chunk 320)))
        (incf ca2 (+ (chunk 128) (chunk 384)))
        (incf ca3 (+ (chunk 192) (chunk 448)))))
    (let ((chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) chars))
      (loop for j of-type fixnum from loop-end below size
            unless (= (logand (sb-sys:sap-ref-8 sap j) #xC0) #x80)
              do (incf chars))
      (values nil nil (the fixnum chars)))))

(declaim (inline count-chars-utf8-strict-512))
(defun count-chars-utf8-strict-512 (sap size &optional (ed-init-state 0))
  (declare (type fixnum size)
           (type (unsigned-byte 8) ed-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (v80 +utf8-v80+)
        (v0 +utf8-v0+)
        (v194 +utf8-v194+)
        (v244 +utf8-v244+)
        (ved +utf8-ved+)
        (va0 +utf8-va0+)
        (vbf +utf8-vbf+)
        (prev-was-ed (if (zerop ed-init-state) 0 1))
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 v80 v0 v194 v244 ved va0 vbf)
             (type (unsigned-byte 64) ca0 ca1 ca2 ca3 prev-was-ed))
    (macrolet ((chunk (offset ca)
                 `(multiple-value-bind (valid ed)
                      (utf8-strict-bits-512
                       (avx512bw:u8.64-sap-ref sap (+ i ,offset))
                       prev-was-ed v80 v0 v194 v244 ved va0 vbf)
                    (setf prev-was-ed (ash ed -63))
                    (incf ,ca (popcount64 valid)))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   ca0)
        (chunk 64  ca1)
        (chunk 128 ca2)
        (chunk 192 ca3)
        (chunk 256 ca0)
        (chunk 320 ca1)
        (chunk 384 ca2)
        (chunk 448 ca3)))
    (let ((chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for ascii = (<= 0 byte 127)
            for vlead = (<= 194 byte 244)
            for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
            do (when (and (or ascii vlead) (not bad)) (incf chars))
               (setf prev-was-ed (if (= byte #xED) 1 0)))
      (values nil nil (the fixnum chars)))))

(defun count-chars-utf8-strict-avx512 (sap size &optional (ed-init-state 0))
  (count-chars-utf8-strict-512 sap size ed-init-state))

(defun count-chars-ascii-avx512 (sap size)
  (declare (ignore sap))
  (values nil nil size))


;;; count lines and words

(declaim (inline count-lines-and-words))
(defun count-lines-and-words (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (ws-lut +ws-lut+)
        (lf-vec +lf-vec+)
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (la0 0) (la1 0) (la2 0) (la3 0)
        (wa0 0) (wa1 0) (wa2 0) (wa3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 ws-lut lf-vec)
             (type (unsigned-byte 64) la0 la1 la2 la3 wa0 wa1 wa2 wa3 prev-was-ws))
    (macrolet ((chunk (offset la wa)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c ws-lut))
                         (lf-mask (line-bits-512 c lf-vec))
                         (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask lf-mask shifted starts))
                    (setf prev-was-ws (ash ws-mask -63))
                    (incf ,la (popcount64 lf-mask))
                    (incf ,wa (popcount64 starts)))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   la0 wa0)
        (chunk 64  la1 wa1)
        (chunk 128 la2 wa2)
        (chunk 192 la3 wa3)
        (chunk 256 la0 wa0)
        (chunk 320 la1 wa1)
        (chunk 384 la2 wa2)
        (chunk 448 la3 wa3)))
    (let ((lines (+ la0 la1 la2 la3))
          (words (+ wa0 wa1 wa2 wa3)))
      (declare (type (unsigned-byte 64) lines words))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (= byte 10) (incf lines))
               (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (setf prev-was-ws (if is-ws 1 0)))
      (values (the fixnum lines) (the fixnum words) nil))))

(defun count-lines-and-words-utf8-avx512 (sap size ws-init-state)
  (count-lines-and-words sap size ws-init-state))
(defun count-lines-and-words-ascii-avx512 (sap size ws-init-state)
  (count-lines-and-words sap size ws-init-state))


;;; count lines and chars

(declaim (inline count-lines-and-chars-utf8-strict-512))
(defun count-lines-and-chars-utf8-strict-512 (sap size &optional (ed-init-state 0))
  (declare (type fixnum size)
           (type (unsigned-byte 8) ed-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (lf-vec +lf-vec+)
        (v80 +utf8-v80+)
        (v0 +utf8-v0+)
        (v194 +utf8-v194+)
        (v244 +utf8-v244+)
        (ved +utf8-ved+)
        (va0 +utf8-va0+)
        (vbf +utf8-vbf+)
        (prev-was-ed (if (zerop ed-init-state) 0 1))
        (la0 0) (la1 0) (la2 0) (la3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 lf-vec v80 v0 v194 v244 ved va0 vbf)
             (type (unsigned-byte 64) la0 la1 la2 la3 ca0 ca1 ca2 ca3 prev-was-ed))
    (macrolet ((chunk (offset la ca)
                 `(let ((c (avx512bw:u8.64-sap-ref sap (+ i ,offset))))
                    (multiple-value-bind (valid ed)
                        (utf8-strict-bits-512 c prev-was-ed v80 v0 v194 v244 ved va0 vbf)
                      (setf prev-was-ed (ash ed -63))
                      (incf ,la (popcount64 (line-bits-512 c lf-vec)))
                      (incf ,ca (popcount64 valid))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   la0 ca0)
        (chunk 64  la1 ca1)
        (chunk 128 la2 ca2)
        (chunk 192 la3 ca3)
        (chunk 256 la0 ca0)
        (chunk 320 la1 ca1)
        (chunk 384 la2 ca2)
        (chunk 448 la3 ca3)))
    (let ((lines (+ la0 la1 la2 la3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) lines chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for ascii = (<= 0 byte 127)
            for vlead = (<= 194 byte 244)
            for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
            do (when (= byte 10) (incf lines))
               (when (and (or ascii vlead) (not bad)) (incf chars))
               (setf prev-was-ed (if (= byte #xED) 1 0)))
      (values (the fixnum lines) nil (the fixnum chars)))))

(defun count-lines-and-chars-utf8-strict-avx512 (sap size &optional (ed-init-state 0))
  (count-lines-and-chars-utf8-strict-512 sap size ed-init-state))

(defun count-lines-and-chars-utf8-avx512 (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (lf-vec +lf-vec+)
        (c0-vec +cont-c0+)
        (80-vec +cont-80+)
        (la0 0) (la1 0) (la2 0) (la3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 lf-vec c0-vec 80-vec)
             (type (unsigned-byte 64) la0 la1 la2 la3 ca0 ca1 ca2 ca3))
    (macrolet ((chunk (offset la ca)
                 `(let ((c (avx512bw:u8.64-sap-ref sap (+ i ,offset))))
                    (incf ,la (popcount64 (line-bits-512 c lf-vec)))
                    (incf ,ca (popcount64
                               (logand #xFFFFFFFFFFFFFFFF
                                       (lognot (cont-bits-512 c c0-vec 80-vec))))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   la0 ca0)
        (chunk 64  la1 ca1)
        (chunk 128 la2 ca2)
        (chunk 192 la3 ca3)
        (chunk 256 la0 ca0)
        (chunk 320 la1 ca1)
        (chunk 384 la2 ca2)
        (chunk 448 la3 ca3)))
    (let ((lines (+ la0 la1 la2 la3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) lines chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            do (when (= byte 10) (incf lines))
               (when (/= (logand byte #xC0) #x80) (incf chars)))
      (values (the fixnum lines) nil (the fixnum chars)))))

(defun count-lines-and-chars-ascii-avx512 (sap size)
  (multiple-value-bind (lines) (count-lines-512 sap size)
    (values lines nil size)))


;;; count words and chars

(declaim (inline count-words-and-chars-utf8-strict-512))
(defun count-words-and-chars-utf8-strict-512 (sap size ws-init-state &optional (ed-init-state 0))
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state ed-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (ws-lut +ws-lut+)
        (v80 +utf8-v80+)
        (v0 +utf8-v0+)
        (v194 +utf8-v194+)
        (v244 +utf8-v244+)
        (ved +utf8-ved+)
        (va0 +utf8-va0+)
        (vbf +utf8-vbf+)
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (prev-was-ed (if (zerop ed-init-state) 0 1))
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 ws-lut v80 v0 v194 v244 ved va0 vbf)
             (type (unsigned-byte 64) wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3 prev-was-ws prev-was-ed))
    (macrolet ((chunk (offset wa ca)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c ws-lut))
                         (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                         (starts  (logandc2 shifted ws-mask)))
                    (multiple-value-bind (valid ed)
                        (utf8-strict-bits-512 c prev-was-ed v80 v0 v194 v244 ved va0 vbf)
                      (setf prev-was-ws (ash ws-mask -63))
                      (setf prev-was-ed (ash ed -63))
                      (incf ,wa (popcount64 starts))
                      (incf ,ca (popcount64 valid))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   wa0 ca0)
        (chunk 64  wa1 ca1)
        (chunk 128 wa2 ca2)
        (chunk 192 wa3 ca3)
        (chunk 256 wa0 ca0)
        (chunk 320 wa1 ca1)
        (chunk 384 wa2 ca2)
        (chunk 448 wa3 ca3)))
    (let ((words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) words chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            for ascii = (<= 0 byte 127)
            for vlead = (<= 194 byte 244)
            for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
            do (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (when (and (or ascii vlead) (not bad)) (incf chars))
               (setf prev-was-ws (if is-ws 1 0)
                     prev-was-ed (if (= byte #xED) 1 0)))
      (values nil (the fixnum words) (the fixnum chars)))))

(defun count-words-and-chars-utf8-strict-avx512 (sap size ws-init-state &optional (ed-init-state 0))
  (count-words-and-chars-utf8-strict-512 sap size ws-init-state ed-init-state))

(defun count-words-and-chars-utf8-avx512 (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (ws-lut +ws-lut+)
        (c0-vec +cont-c0+)
        (80-vec +cont-80+)
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 ws-lut c0-vec 80-vec)
             (type (unsigned-byte 64) wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3 prev-was-ws))
    (macrolet ((chunk (offset wa ca)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c ws-lut))
                         (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask shifted starts))
                    (setf prev-was-ws (ash ws-mask -63))
                    (incf ,wa (popcount64 starts))
                    (incf ,ca (popcount64
                               (logand #xFFFFFFFFFFFFFFFF
                                       (lognot (cont-bits-512 c c0-vec 80-vec))))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   wa0 ca0)
        (chunk 64  wa1 ca1)
        (chunk 128 wa2 ca2)
        (chunk 192 wa3 ca3)
        (chunk 256 wa0 ca0)
        (chunk 320 wa1 ca1)
        (chunk 384 wa2 ca2)
        (chunk 448 wa3 ca3)))
    (let ((words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) words chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (when (/= (logand byte #xC0) #x80) (incf chars))
               (setf prev-was-ws (if is-ws 1 0)))
      (values nil (the fixnum words) (the fixnum chars)))))

(defun count-words-and-chars-ascii-avx512 (sap size ws-init-state)
  (multiple-value-bind (lines words) (count-lines-and-words sap size ws-init-state)
    (declare (ignore lines))
    (values nil words size)))


;;; count lines, words and chars

(declaim (inline count-lines-words-and-chars-utf8-strict-512))
(declaim (inline count-lines-words-and-chars-utf8-strict-512))
(defun count-lines-words-and-chars-utf8-strict-512 (sap size ws-init-state &optional (ed-init-state 0))
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state ed-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (ws-lut +ws-lut+)
        (lf-vec +lf-vec+)
        (v80 +utf8-v80+)
        (v0 +utf8-v0+)
        (v194 +utf8-v194+)
        (v244 +utf8-v244+)
        (ved +utf8-ved+)
        (va0 +utf8-va0+)
        (vbf +utf8-vbf+)
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (prev-was-ed (if (zerop ed-init-state) 0 1))
        (la0 0) (la1 0) (la2 0) (la3 0)
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 ws-lut lf-vec v80 v0 v194 v244 ved va0 vbf)
             (type (unsigned-byte 64) la0 la1 la2 la3 wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3 prev-was-ws prev-was-ed))
    (macrolet ((chunk (offset la wa ca)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c ws-lut))
                         (lf-mask (line-bits-512 c lf-vec))
                         (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                         (starts  (logandc2 shifted ws-mask)))
                    (multiple-value-bind (valid ed)
                        (utf8-strict-bits-512 c prev-was-ed v80 v0 v194 v244 ved va0 vbf)
                      (setf prev-was-ws (ash ws-mask -63))
                      (setf prev-was-ed (ash ed -63))
                      (incf ,la (popcount64 lf-mask))
                      (incf ,wa (popcount64 starts))
                      (incf ,ca (popcount64 valid))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   la0 wa0 ca0)
        (chunk 64  la1 wa1 ca1)
        (chunk 128 la2 wa2 ca2)
        (chunk 192 la3 wa3 ca3)
        (chunk 256 la0 wa0 ca0)
        (chunk 320 la1 wa1 ca1)
        (chunk 384 la2 wa2 ca2)
        (chunk 448 la3 wa3 ca3)))
    (let ((lines (+ la0 la1 la2 la3))
          (words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) lines words chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            for ascii = (<= 0 byte 127)
            for vlead = (<= 194 byte 244)
            for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
            do (when (= byte 10) (incf lines))
               (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (when (and (or ascii vlead) (not bad)) (incf chars))
               (setf prev-was-ws (if is-ws 1 0)
                     prev-was-ed (if (= byte #xED) 1 0)))
      (values (the fixnum lines) (the fixnum words) (the fixnum chars)))))

(defun count-lines-words-and-chars-utf8-strict-avx512 (sap size ws-init-state &optional (ed-init-state 0))
  (count-lines-words-and-chars-utf8-strict-512 sap size ws-init-state ed-init-state))

(defun count-lines-words-and-chars-utf8-avx512 (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (ws-lut +ws-lut+)
        (lf-vec +lf-vec+)
        (c0-vec +cont-c0+)
        (80-vec +cont-80+)
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (la0 0) (la1 0) (la2 0) (la3 0)
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type avx512bw:u8.64 ws-lut lf-vec c0-vec 80-vec)
             (type (unsigned-byte 64) la0 la1 la2 la3 wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3 prev-was-ws))
    (macrolet ((chunk (offset la wa ca)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c ws-lut))
                         (lf-mask (line-bits-512 c lf-vec))
                         (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask lf-mask shifted starts))
                    (setf prev-was-ws (ash ws-mask -63))
                    (incf ,la (popcount64 lf-mask))
                    (incf ,wa (popcount64 starts))
                    (incf ,ca (popcount64
                               (logand #xFFFFFFFFFFFFFFFF
                                       (lognot (cont-bits-512 c c0-vec 80-vec))))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (chunk 0   la0 wa0 ca0)
        (chunk 64  la1 wa1 ca1)
        (chunk 128 la2 wa2 ca2)
        (chunk 192 la3 wa3 ca3)
        (chunk 256 la0 wa0 ca0)
        (chunk 320 la1 wa1 ca1)
        (chunk 384 la2 wa2 ca2)
        (chunk 448 la3 wa3 ca3)))
    (let ((lines (+ la0 la1 la2 la3))
          (words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type (unsigned-byte 64) lines words chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (= byte 10) (incf lines))
               (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (when (/= (logand byte #xC0) #x80) (incf chars))
               (setf prev-was-ws (if is-ws 1 0)))
      (values (the fixnum lines) (the fixnum words) (the fixnum chars)))))

(defun count-lines-words-and-chars-ascii-avx512 (sap size ws-init-state)
  (multiple-value-bind (lines words) (count-lines-and-words sap size ws-init-state)
    (values lines words size)))

;;; kernels-avx512.cl ends here
