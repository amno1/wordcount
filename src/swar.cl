;; swar.cl
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

;; Only 64-bit

;;; Code:

(declaim (optimize (speed 3) (safety 0) (debug 0)))

(in-package #:swar)

;; (declaim (inline new-line-count swar:fpopcount
;;                  word-crossing-count utf8-count-fast utf8-count-strict))

;; (defun fpopcount (x)
;;   (declare (type (unsigned-byte 64) x)
;;            (ignore x)
;;            (optimize (speed 3) (safety 0) (debug 0)))
;;   (error "FPOPCOUNT VOP not selected"))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (sb-c:defknown swar::fpopcount ((unsigned-byte 64)) fixnum
      (sb-c:flushable sb-c:movable)
    :overwrite-fndb-silently t))

(sb-c:deftransform swar::fpopcount ((x) ((unsigned-byte 64)) *)
  '(sb-c::%primitive swar::fpopcount x))

(in-package "SB-VM")

(define-vop (swar::fpopcount-unboxed)
  (:policy :fast-safe)
  (:translate swar::fpopcount)
  (:args (x :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:results (r :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:generator 2
    (inst popcnt r x)))

(define-vop (swar::fpopcount-boxed)
  (:policy :fast-safe)
  (:translate swar::fpopcount)
  (:args (x :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:results (r :scs (any-reg)))
  (:result-types fixnum)
  (:generator 2
    (inst popcnt r x)
    (inst shl r 1)))

(in-package #:swar)

(defmacro gen-white-space-mask (chunk)
  (declare (type (unsigned-byte 64) chunk))
  `(let* ((xor (logxor ,chunk #x2020202020202020))
          (sub (ldb (byte 64 0) (- xor #x0101010101010101)))
          (mask (logand (lognot xor) sub #x8080808080808080))
          (sub9 (ldb (byte 64 0) (- ,chunk #x0909090909090909)))
          (add7b (ldb (byte 64 0) (+ sub9 #x7B7B7B7B7B7B7B7B)))
          (range-mask (logandc2 #x8080808080808080 (logior sub9 add7b))))
     (declare (type (unsigned-byte 64) xor sub mask sub9 add7b range-mask))
     (logior mask range-mask)))

(defmacro word-crossing-count (chunk prev)
  (declare (type (unsigned-byte 64) chunk)
           (type (unsigned-byte 8) prev))
  `(let* ((shifted (logior (ldb (byte 64 0) (ash ,chunk 8)) ,prev))
          (transitions (logand shifted (lognot ,chunk) #x8080808080808080)))
     (declare (type (unsigned-byte 64) shifted transitions))
     (sb-c::%primitive fpopcount-boxed transitions)))

(defmacro null-byte-count (chunk)
  (declare (type (unsigned-byte 64) chunk))
  `(let* ((x (logxor ,chunk #x0A0A0A0A0A0A0A0A))
          (s (ldb (byte 64 0) (- x #x0101010101010101)))
          (r (logand (lognot x) s #x8080808080808080)))
     (declare (type (unsigned-byte 64) x s r))
     (sb-c::%primitive fpopcount-boxed r)))

(pushnew :popcnt sb-c:*backend-subfeatures*)
(declaim (inline new-line-count))
(defun new-line-count (chunk)
  (declare (type (unsigned-byte 64) chunk))
  `(let* ((x (logxor ,chunk #x0A0A0A0A0A0A0A0A))
          (s (ldb (byte 64 0) (- x #x0101010101010101)))
          (r (logand (lognot x) s #x8080808080808080)))
     (declare (type (unsigned-byte 64) x s r))
     ;;(sb-c::%primitive fpopcount-boxed r)
     (logcount r)))

(defmacro utf8-count-fast (chunk)
  (declare (type (unsigned-byte 64) chunk))
  `(let* ((shifted (ash ,chunk 1))
          (cont-mask (logand ,chunk (lognot shifted) #x8080808080808080))
          (cont-count (sb-c::%primitive fpopcount-unboxed cont-mask)))
     (declare (type (unsigned-byte 64) shifted cont-mask)
              (type fixnum cont-count))
     (the fixnum (- 8 cont-count))))

(defmacro utf8-count-strict (chunk)
  (declare (type (unsigned-byte 64) chunk))
  `(let* ((ascii-mask (logand (lognot ,chunk) #x8080808080808080))
         (sub194 (ldb (byte 64 0) (- ,chunk #xC2C2C2C2C2C2C2C2)))
         (add77  (ldb (byte 64 0) (+ sub194 #x4D4D4D4D4D4D4D4D)))
         (range-mask (logandc2 #x8080808080808080 (logior sub194 add77)))
         (valid-starts (logior ascii-mask range-mask)))
    (declare (type (unsigned-byte 64) ascii-mask sub194 add77 range-mask valid-starts))
    (sb-c::%primitive fpopcount-boxed valid-starts)))

;;; swar.cl ends here
