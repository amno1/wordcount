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
;; Some choices made:
;;
;;   * Byte comparisons (U8.64-MASK=, -MASK<=, -MASK>=) return an
;;     M8.64, sb-simd's type for a 64-lane k-register mask; they are
;;     combined in the k-register with M8.64-AND / M8.64-OR (KANDQ /
;;     KORQ) and only then moved to a GPR.
;;
;;   * MASK64-BITS is sb-simd's M8.64-VALUE, which is inline over
;;     SB-KERNEL:%SIMD-PACK-512-MASK-VALUE; that primitive's VOP
;;     accepts :SCS (mask-reg descriptor-reg), so on a mask that is
;;     already in a k-register it compiles to a bare KMOVQ, with no
;;     boxing and no allocation.
;;
;;   * POPCOUNT64 is WC::FPOPCOUNT (see common.cl), a one-instruction
;;     POPCNT with no per-call TEST of the CPU-FEATURE-BITS. COMMON.CL
;;     must be loaded before this file so the DEFKNOWN/DEFTRANSFORM
;;     are visible to the compiler.
;;
;;   * All four (or eight) chunk classifications in the inner loop are
;;     written out via MACROLET, not FLET. SBCL does not inline FLET
;;     bodies, so FLET-based kernels emit a CALL per chunk; MACROLET
;;     expands to inline code with no call boundary.  Each chunk feeds
;;     one of four independent scalar accumulators so the four adds do
;;     not serialise on a single counter. If you know how to get SBCL
;;     to inline FLET calls, please let me know.

;;; Code:
#-sbcl
(error "This file requires SBCL compiler.")
#-avx512
(error "This file requires an SBCL/sb-simd build with AVX-512 support.")

(declaim (optimize (speed 3) (safety 0)))

(in-package :wc)

(declaim (inline count-lines-words-and-chars-utf8
                 count-lines-words-and-chars-ascii
                 count-lines-utf8 count-words-utf8 count-chars-utf8
                 count-lines-ascii count-words-ascii count-chars-ascii
                 count-lines-and-words-utf8 count-words-and-chars-utf8
                 count-lines-and-chars-utf8
                 count-lines-and-words-ascii count-words-and-chars-ascii
                 count-lines-and-chars-ascii))


;;; helpers

;;; Extract the 64-bit mask from an M8.64 k-register value.
;;;
;;; AVX512BW:M8.64-VALUE is declaimed inline and expands to
;;; SB-KERNEL:%SIMD-PACK-512-MASK-VALUE, whose VOP takes the mask
;;; straight from a k-register: on the value returned by U8.64-MASK=
;;; this is a single KMOVQ, no allocation.
(declaim (inline mask64-bits))
(defun mask64-bits (m)
  (declare (type avx512bw:m8.64 m)
           (optimize (speed 3) (safety 0)))
  (the (unsigned-byte 64) (avx512bw:m8.64-value m)))

;;; Bare POPCNT.  FPOPCOUNT is DEFKNOWN'd on (UNSIGNED-BYTE 64)
;;; and routed by DEFTRANSFORM to a primitive whose VOP emits just
;;; POPCNT (+ SHL 1 for the fixnum tag); no runtime CPU-feature test,
;;; unlike SBCL's LOGCOUNT on the same type.
(declaim (inline popcount64))
(defun popcount64 (m)
  (declare (type (unsigned-byte 64) m)
           (optimize (speed 3) (safety 0)))
  (the fixnum (wc::fpopcount m)))

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

(declaim (inline ws-bits-512))
;; Bit N set iff byte N of CHUNK is ASCII whitespace.
(defun ws-bits-512 (chunk)
  (declare (type avx512bw:u8.64 chunk)
           (optimize (speed 3) (safety 0)))
  (mask64-bits
   (avx512bw:m8.64-or
    (avx512bw:m8.64-and (avx512bw:u8.64-mask>= chunk (avx512bw:u8.64 9))
                          (avx512bw:u8.64-mask<= chunk (avx512bw:u8.64 13)))
    (avx512bw:u8.64-mask= chunk (avx512bw:u8.64 32)))))

(declaim (inline line-bits-512))
;; Bit N set iff byte N of CHUNK is \\n.
(defun line-bits-512 (chunk)
  (declare (type avx512bw:u8.64 chunk)
           (optimize (speed 3) (safety 0)))
  (mask64-bits (avx512bw:u8.64-mask= chunk (avx512bw:u8.64 10))))

(declaim (inline cont-bits-512))
;; Bit N set iff byte N of CHUNK is a UTF-8 continuation byte.
(defun cont-bits-512 (chunk)
  (declare (type avx512bw:u8.64 chunk)
           (optimize (speed 3) (safety 0)))
  (mask64-bits
   (avx512bw:u8.64-mask=
    (avx512bw:u8.64-and chunk (avx512bw:u8.64 #xC0))
    (avx512bw:u8.64 #x80))))

(declaim (inline utf8-strict-bits-512))
;; Return (VALUES VALID ED) for strict UTF-8 start-byte classification.
(defun utf8-strict-bits-512 (chunk prev-was-ed)
  (declare (type avx512bw:u8.64 chunk)
           (type (unsigned-byte 1) prev-was-ed)
           (optimize (speed 3) (safety 0)))
  (let* ((ascii-bits (mask64-bits
                       (avx512bw:u8.64-mask=
                        (avx512bw:u8.64-and chunk (avx512bw:u8.64 #x80))
                        (avx512bw:u8.64 0))))
         (vlead-bits (mask64-bits
                       (avx512bw:m8.64-and
                        (avx512bw:u8.64-mask>= chunk (avx512bw:u8.64 194))
                        (avx512bw:u8.64-mask<= chunk (avx512bw:u8.64 244)))))
         (ed-bits    (mask64-bits
                       (avx512bw:u8.64-mask= chunk (avx512bw:u8.64 #xED))))
         (ed-shift   (logand #xFFFFFFFFFFFFFFFF
                             (logior (ash ed-bits 1) prev-was-ed)))
         (foll-bits  (mask64-bits
                       (avx512bw:m8.64-and
                        (avx512bw:u8.64-mask>= chunk (avx512bw:u8.64 #xA0))
                        (avx512bw:u8.64-mask<= chunk (avx512bw:u8.64 #xBF)))))
         (bad-bits   (logand ed-shift foll-bits))
         (valid-bits (logandc2 (logior ascii-bits vlead-bits) bad-bits)))
    (declare (type (unsigned-byte 64)
                   ascii-bits vlead-bits ed-bits ed-shift foll-bits bad-bits valid-bits))
    (values valid-bits ed-bits)))


;;; count lines

(declaim (inline count-lines))
(defun count-lines (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (la0 0) (la1 0) (la2 0) (la3 0))
    (declare (type fixnum loop-end)
             (type acc-count la0 la1 la2 la3))
    (macrolet ((chunk (offset)
                 `(popcount64
                   (line-bits-512
                    (avx512bw:u8.64-sap-ref sap (+ i ,offset))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (incf la0 (+ (chunk 0)   (chunk 256)))
        (incf la1 (+ (chunk 64)  (chunk 320)))
        (incf la2 (+ (chunk 128) (chunk 384)))
        (incf la3 (+ (chunk 192) (chunk 448)))))
    (let ((lines (+ la0 la1 la2 la3)))
      (declare (type fixnum lines))
      (loop for j of-type fixnum from loop-end below size
            when (= (sb-sys:sap-ref-8 sap j) 10)
              do (incf lines))
      (values lines nil nil))))

(defun count-lines-utf8-avx512 (sap size)  (count-lines sap size))
(defun count-lines-ascii-avx512 (sap size) (count-lines sap size))


;;; count words

(declaim (inline count-words))
(defun count-words (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (wa0 0) (wa1 0) (wa2 0) (wa3 0))
    (declare (type fixnum loop-end)
             (type acc-count wa0 wa1 wa2 wa3)
             (type (unsigned-byte 1) prev-was-ws))
    (macrolet ((chunk (offset)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c))
                         (shifted (logand #xFFFFFFFFFFFFFFFF
                                          (logior (ash ws-mask 1) prev-was-ws)))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask shifted starts))
                    (setf prev-was-ws (if (logbitp 63 ws-mask) 1 0))
                    (popcount64 starts))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        ;; each CHUNK call mutates PREV-WAS-WS, so the eight calls
        ;; must execute in ascending (i.e. true byte) order unlike
        ;; COUNT-LINES' CHUNK above, which is pure and can be paired
        ;; up freely for four independent accumulator chains.
        (incf wa0 (chunk 0))
        (incf wa1 (chunk 64))
        (incf wa2 (chunk 128))
        (incf wa3 (chunk 192))
        (incf wa0 (chunk 256))
        (incf wa1 (chunk 320))
        (incf wa2 (chunk 384))
        (incf wa3 (chunk 448))))
    (let ((words (+ wa0 wa1 wa2 wa3)))
      (declare (type fixnum words))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (setf prev-was-ws (if is-ws 1 0)))
      (values nil words nil))))

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
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count ca0 ca1 ca2 ca3))
    (macrolet ((chunk (offset)
                 `(popcount64
                   (logand #xFFFFFFFFFFFFFFFF
                           (lognot (cont-bits-512
                                    (avx512bw:u8.64-sap-ref
                                     sap (+ i ,offset))))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (incf ca0 (+ (chunk 0)   (chunk 256)))
        (incf ca1 (+ (chunk 64)  (chunk 320)))
        (incf ca2 (+ (chunk 128) (chunk 384)))
        (incf ca3 (+ (chunk 192) (chunk 448)))))
    (let ((chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum chars))
      (loop for j of-type fixnum from loop-end below size
            unless (= (logand (sb-sys:sap-ref-8 sap j) #xC0) #x80)
              do (incf chars))
      (values nil nil chars))))

(declaim (inline count-chars-utf8-strict))
(defun count-chars-utf8-strict (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (prev-was-ed 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count ca0 ca1 ca2 ca3)
             (type (unsigned-byte 1) prev-was-ed))
    (macrolet ((chunk (offset)
                 `(multiple-value-bind (valid ed)
                      (utf8-strict-bits-512
                       (avx512bw:u8.64-sap-ref sap (+ i ,offset))
                       prev-was-ed)
                    (setf prev-was-ed (if (logbitp 63 ed) 1 0))
                    (popcount64 valid))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        ;; each CHUNK call mutates PREV-WAS-ED, so the eight calls
        ;; must execute in ascending (i.e. true byte) order -- see
        ;; the same note on COUNT-WORDS above.
        (incf ca0 (chunk 0))
        (incf ca1 (chunk 64))
        (incf ca2 (chunk 128))
        (incf ca3 (chunk 192))
        (incf ca0 (chunk 256))
        (incf ca1 (chunk 320))
        (incf ca2 (chunk 384))
        (incf ca3 (chunk 448))))
    (let ((chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for ascii = (<= 0 byte 127)
            for vlead = (<= 194 byte 244)
            for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
            do (when (and (or ascii vlead) (not bad)) (incf chars))
               (setf prev-was-ed (if (= byte #xED) 1 0)))
      (values nil nil chars))))

(defun count-chars-utf8-strict-avx512 (sap size)
  (count-chars-utf8-strict sap size))

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
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (la0 0) (la1 0) (la2 0) (la3 0)
        (wa0 0) (wa1 0) (wa2 0) (wa3 0))
    (declare (type fixnum loop-end)
             (type acc-count la0 la1 la2 la3 wa0 wa1 wa2 wa3)
             (type (unsigned-byte 1) prev-was-ws))
    (macrolet ((chunk (offset)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c))
                         (shifted (logand #xFFFFFFFFFFFFFFFF
                                          (logior (ash ws-mask 1) prev-was-ws)))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask shifted starts))
                    (setf prev-was-ws (if (logbitp 63 ws-mask) 1 0))
                    (values (popcount64 (line-bits-512 c))
                            (popcount64 starts)))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (multiple-value-bind (l w) (chunk 0)
          (incf la0 l) (incf wa0 w))
        (multiple-value-bind (l w) (chunk 64)
          (incf la1 l) (incf wa1 w))
        (multiple-value-bind (l w) (chunk 128)
          (incf la2 l) (incf wa2 w))
        (multiple-value-bind (l w) (chunk 192)
          (incf la3 l) (incf wa3 w))
        (multiple-value-bind (l w) (chunk 256)
          (incf la0 l) (incf wa0 w))
        (multiple-value-bind (l w) (chunk 320)
          (incf la1 l) (incf wa1 w))
        (multiple-value-bind (l w) (chunk 384)
          (incf la2 l) (incf wa2 w))
        (multiple-value-bind (l w) (chunk 448)
          (incf la3 l) (incf wa3 w))))
    (let ((lines (+ la0 la1 la2 la3))
          (words (+ wa0 wa1 wa2 wa3)))
      (declare (type fixnum lines words))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (= byte 10) (incf lines))
               (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (setf prev-was-ws (if is-ws 1 0)))
      (values lines words nil))))

(defun count-lines-and-words-utf8-avx512 (sap size ws-init-state)
  (count-lines-and-words sap size ws-init-state))
(defun count-lines-and-words-ascii-avx512 (sap size ws-init-state)
  (count-lines-and-words sap size ws-init-state))


;;; count lines and chars

(declaim (inline count-lines-and-chars-utf8-strict))
(defun count-lines-and-chars-utf8-strict (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (prev-was-ed 0)
        (la0 0) (la1 0) (la2 0) (la3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count la0 la1 la2 la3 ca0 ca1 ca2 ca3)
             (type (unsigned-byte 1) prev-was-ed))
    (macrolet ((chunk (offset)
                 `(let ((c (avx512bw:u8.64-sap-ref sap (+ i ,offset))))
                    (multiple-value-bind (valid ed)
                        (utf8-strict-bits-512 c prev-was-ed)
                      (setf prev-was-ed (if (logbitp 63 ed) 1 0))
                      (values (popcount64 (line-bits-512 c))
                              (popcount64 valid))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (multiple-value-bind (l c) (chunk 0)
          (incf la0 l) (incf ca0 c))
        (multiple-value-bind (l c) (chunk 64)
          (incf la1 l) (incf ca1 c))
        (multiple-value-bind (l c) (chunk 128)
          (incf la2 l) (incf ca2 c))
        (multiple-value-bind (l c) (chunk 192)
          (incf la3 l) (incf ca3 c))
        (multiple-value-bind (l c) (chunk 256)
          (incf la0 l) (incf ca0 c))
        (multiple-value-bind (l c) (chunk 320)
          (incf la1 l) (incf ca1 c))
        (multiple-value-bind (l c) (chunk 384)
          (incf la2 l) (incf ca2 c))
        (multiple-value-bind (l c) (chunk 448)
          (incf la3 l) (incf ca3 c))))
    (let ((lines (+ la0 la1 la2 la3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum lines chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for ascii = (<= 0 byte 127)
            for vlead = (<= 194 byte 244)
            for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
            do (when (= byte 10) (incf lines))
               (when (and (or ascii vlead) (not bad)) (incf chars))
               (setf prev-was-ed (if (= byte #xED) 1 0)))
      (values lines nil chars))))

(defun count-lines-and-chars-utf8-strict-avx512 (sap size)
  (count-lines-and-chars-utf8-strict sap size))

(defun count-lines-and-chars-utf8-avx512 (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (la0 0) (la1 0) (la2 0) (la3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count la0 la1 la2 la3 ca0 ca1 ca2 ca3))
    (macrolet ((chunk (offset)
                 `(let ((c (avx512bw:u8.64-sap-ref sap (+ i ,offset))))
                    (values (popcount64 (line-bits-512 c))
                            (popcount64
                             (logand #xFFFFFFFFFFFFFFFF
                                     (lognot (cont-bits-512 c))))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (multiple-value-bind (l c) (chunk 0)
          (incf la0 l) (incf ca0 c))
        (multiple-value-bind (l c) (chunk 64)
          (incf la1 l) (incf ca1 c))
        (multiple-value-bind (l c) (chunk 128)
          (incf la2 l) (incf ca2 c))
        (multiple-value-bind (l c) (chunk 192)
          (incf la3 l) (incf ca3 c))
        (multiple-value-bind (l c) (chunk 256)
          (incf la0 l) (incf ca0 c))
        (multiple-value-bind (l c) (chunk 320)
          (incf la1 l) (incf ca1 c))
        (multiple-value-bind (l c) (chunk 384)
          (incf la2 l) (incf ca2 c))
        (multiple-value-bind (l c) (chunk 448)
          (incf la3 l) (incf ca3 c))))
    (let ((lines (+ la0 la1 la2 la3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum lines chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            do (when (= byte 10) (incf lines))
               (when (/= (logand byte #xC0) #x80) (incf chars)))
      (values lines nil chars))))

(defun count-lines-and-chars-ascii-avx512 (sap size)
  (multiple-value-bind (lines) (count-lines sap size)
    (values lines nil size)))


;;; count words and chars

(declaim (inline count-words-and-chars-utf8-strict))
(defun count-words-and-chars-utf8-strict (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (prev-was-ed 0)
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3)
             (type (unsigned-byte 1) prev-was-ws prev-was-ed))
    (macrolet ((chunk (offset)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c))
                         (shifted (logand #xFFFFFFFFFFFFFFFF
                                          (logior (ash ws-mask 1) prev-was-ws)))
                         (starts  (logandc2 shifted ws-mask)))
                    (multiple-value-bind (valid ed)
                        (utf8-strict-bits-512 c prev-was-ed)
                      (setf prev-was-ws (if (logbitp 63 ws-mask) 1 0))
                      (setf prev-was-ed (if (logbitp 63 ed) 1 0))
                      (values (popcount64 starts)
                              (popcount64 valid))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (multiple-value-bind (w c) (chunk 0)
          (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (w c) (chunk 64)
          (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (w c) (chunk 128)
          (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (w c) (chunk 192)
          (incf wa3 w) (incf ca3 c))
        (multiple-value-bind (w c) (chunk 256)
          (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (w c) (chunk 320)
          (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (w c) (chunk 384)
          (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (w c) (chunk 448)
          (incf wa3 w) (incf ca3 c))))
    (let ((words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum words chars))
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
      (values nil words chars))))

(defun count-words-and-chars-utf8-strict-avx512 (sap size ws-init-state)
  (count-words-and-chars-utf8-strict sap size ws-init-state))

(defun count-words-and-chars-utf8-avx512 (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3)
             (type (unsigned-byte 1) prev-was-ws))
    (macrolet ((chunk (offset)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c))
                         (shifted (logand #xFFFFFFFFFFFFFFFF
                                          (logior (ash ws-mask 1) prev-was-ws)))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask shifted starts))
                    (setf prev-was-ws (if (logbitp 63 ws-mask) 1 0))
                    (values (popcount64 starts)
                            (popcount64
                             (logand #xFFFFFFFFFFFFFFFF
                                     (lognot (cont-bits-512 c))))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (multiple-value-bind (w c) (chunk 0)
          (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (w c) (chunk 64)
          (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (w c) (chunk 128)
          (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (w c) (chunk 192)
          (incf wa3 w) (incf ca3 c))
        (multiple-value-bind (w c) (chunk 256)
          (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (w c) (chunk 320)
          (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (w c) (chunk 384)
          (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (w c) (chunk 448)
          (incf wa3 w) (incf ca3 c))))
    (let ((words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum words chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (when (/= (logand byte #xC0) #x80) (incf chars))
               (setf prev-was-ws (if is-ws 1 0)))
      (values nil words chars))))

(defun count-words-and-chars-ascii-avx512 (sap size ws-init-state)
  (multiple-value-bind (lines words) (count-lines-and-words sap size ws-init-state)
    (declare (ignore lines))
    (values nil words size)))


;;; count lines, words and chars

(declaim (inline count-lines-words-and-chars-utf8-strict))
(defun count-lines-words-and-chars-utf8-strict (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (prev-was-ed 0)
        (la0 0) (la1 0) (la2 0) (la3 0)
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count la0 la1 la2 la3 wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3)
             (type (unsigned-byte 1) prev-was-ws prev-was-ed))
    (macrolet ((chunk (offset)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c))
                         (shifted (logand #xFFFFFFFFFFFFFFFF
                                          (logior (ash ws-mask 1) prev-was-ws)))
                         (starts  (logandc2 shifted ws-mask)))
                    (multiple-value-bind (valid ed)
                        (utf8-strict-bits-512 c prev-was-ed)
                      (setf prev-was-ws (if (logbitp 63 ws-mask) 1 0))
                      (setf prev-was-ed (if (logbitp 63 ed) 1 0))
                      (values (popcount64 (line-bits-512 c))
                              (popcount64 starts)
                              (popcount64 valid))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (multiple-value-bind (l w c) (chunk 0)
          (incf la0 l) (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (l w c) (chunk 64)
          (incf la1 l) (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (l w c) (chunk 128)
          (incf la2 l) (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (l w c) (chunk 192)
          (incf la3 l) (incf wa3 w) (incf ca3 c))
        (multiple-value-bind (l w c) (chunk 256)
          (incf la0 l) (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (l w c) (chunk 320)
          (incf la1 l) (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (l w c) (chunk 384)
          (incf la2 l) (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (l w c) (chunk 448)
          (incf la3 l) (incf wa3 w) (incf ca3 c))))
    (let ((lines (+ la0 la1 la2 la3))
          (words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum lines words chars))
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
      (values lines words chars))))

(defun count-lines-words-and-chars-utf8-strict-avx512 (sap size ws-init-state)
  (count-lines-words-and-chars-utf8-strict sap size ws-init-state))

(defun count-lines-words-and-chars-utf8-avx512 (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 511))
        (prev-was-ws (if (zerop ws-init-state) 0 1))
        (la0 0) (la1 0) (la2 0) (la3 0)
        (wa0 0) (wa1 0) (wa2 0) (wa3 0)
        (ca0 0) (ca1 0) (ca2 0) (ca3 0))
    (declare (type fixnum loop-end)
             (type acc-count la0 la1 la2 la3 wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3)
             (type (unsigned-byte 1) prev-was-ws))
    (macrolet ((chunk (offset)
                 `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                         (ws-mask (ws-bits-512 c))
                         (shifted (logand #xFFFFFFFFFFFFFFFF
                                          (logior (ash ws-mask 1) prev-was-ws)))
                         (starts  (logandc2 shifted ws-mask)))
                    (declare (type (unsigned-byte 64) ws-mask shifted starts))
                    (setf prev-was-ws (if (logbitp 63 ws-mask) 1 0))
                    (values (popcount64 (line-bits-512 c))
                            (popcount64 starts)
                            (popcount64
                             (logand #xFFFFFFFFFFFFFFFF
                                     (lognot (cont-bits-512 c))))))))
      (loop for i of-type fixnum from 0 below loop-end by 512 do
        (multiple-value-bind (l w c) (chunk 0)
          (incf la0 l) (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (l w c) (chunk 64)
          (incf la1 l) (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (l w c) (chunk 128)
          (incf la2 l) (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (l w c) (chunk 192)
          (incf la3 l) (incf wa3 w) (incf ca3 c))
        (multiple-value-bind (l w c) (chunk 256)
          (incf la0 l) (incf wa0 w) (incf ca0 c))
        (multiple-value-bind (l w c) (chunk 320)
          (incf la1 l) (incf wa1 w) (incf ca1 c))
        (multiple-value-bind (l w c) (chunk 384)
          (incf la2 l) (incf wa2 w) (incf ca2 c))
        (multiple-value-bind (l w c) (chunk 448)
          (incf la3 l) (incf wa3 w) (incf ca3 c))))
    (let ((lines (+ la0 la1 la2 la3))
          (words (+ wa0 wa1 wa2 wa3))
          (chars (+ ca0 ca1 ca2 ca3)))
      (declare (type fixnum lines words chars))
      (loop for j of-type fixnum from loop-end below size
            for byte = (sb-sys:sap-ref-8 sap j)
            for is-ws = (or (= byte 32) (<= 9 byte 13))
            do (when (= byte 10) (incf lines))
               (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
               (when (/= (logand byte #xC0) #x80) (incf chars))
               (setf prev-was-ws (if is-ws 1 0)))
      (values lines words chars))))

(defun count-lines-words-and-chars-ascii-avx512 (sap size ws-init-state)
  (multiple-value-bind (lines words) (count-lines-and-words sap size ws-init-state)
    (values lines words size)))

;;; kernels-avx512.cl ends here
