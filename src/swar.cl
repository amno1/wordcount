;;; swar.cl
;;; Copyright (C) 2026  Arthur Miller

;;; Author: Arthur Miller <arthur.miller@live.com>
;;; Keywords:

;;; This program is free software; you can redistribute it and/or modify
;;; it under the terms of the GNU General Public License as published by
;;; the Free Software Foundation, either version 3 of the License, or
;;; (at your option) any later version.

;;; This program is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.

;;; You should have received a copy of the GNU General Public License
;;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; 64-bit branchless SWAR macros and VOPs for Common Lisp wordcount.

;;; Code:

(declaim (optimize (speed 3) (safety 0) (debug 0)))

(in-package #:swar)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (sb-c:defknown swar::fpopcount ((unsigned-byte 64)) fixnum
      (sb-c:flushable sb-c:movable)
    :overwrite-fndb-silently t))

(in-package "SB-VM")

(eval-when (:compile-toplevel :load-toplevel :execute)
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
      (inst shl r 1))))

(in-package #:swar)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (pushnew :popcnt sb-c:*backend-subfeatures*))

(defmacro gen-white-space-mask (chunk)
  (let ((c (gensym "CHUNK")))
    `(let* ((,c ,chunk)
            ;; space mask (b == 32): Mycroft zero-byte with 0x80 pre-set to isolate byte lanes
            (x (logxor ,c #x2020202020202020))
            (sub (ldb (byte 64 0) (- (logior x #x8080808080808080) #x0101010101010101)))
            (space (logandc2 #x8080808080808080 (logior sub x)))
            ;; 9 <= b <= 13 (control whitespace): carry-free addition on 7-bit lanes
            (lo (logand ,c #x7F7F7F7F7F7F7F7F))
            (ge9 (ldb (byte 64 0) (+ lo #x7777777777777777)))
            (gt13 (ldb (byte 64 0) (+ lo #x7272727272727272)))
            (range (logand (logandc2 ge9 (logior gt13 ,c)) #x8080808080808080)))
       (declare (type (unsigned-byte 64) ,c x sub space lo ge9 gt13 range))
       (logior space range))))

(defmacro word-crossing-count (curr prev)
  (let ((c (gensym "CURR"))
        (p (gensym "PREV")))
    `(let* ((,c ,curr)
            (,p ,prev)
            (shifted (logior (ldb (byte 64 0) (ash ,c 8)) ,p))
            (transitions (logand shifted (lognot ,c) #x8080808080808080)))
       (declare (type (unsigned-byte 64) ,c shifted transitions)
                (type (unsigned-byte 8) ,p))
       (sb-c::%primitive swar::fpopcount-boxed transitions))))

(defmacro new-line-count (chunk)
  (let ((c (gensym "CHUNK")))
    `(let* ((,c ,chunk)
            (x (logxor ,c #x0A0A0A0A0A0A0A0A))
            (sub (ldb (byte 64 0) (- (logior x #x8080808080808080) #x0101010101010101)))
            (r (logandc2 #x8080808080808080 (logior sub x))))
       (declare (type (unsigned-byte 64) ,c x sub r))
       (sb-c::%primitive swar::fpopcount-boxed r))))

(defmacro null-byte-count (chunk)
  (let ((c (gensym "CHUNK")))
    `(let* ((,c ,chunk)
            (sub (ldb (byte 64 0) (- (logior ,c #x8080808080808080) #x0101010101010101)))
            (r (logandc2 #x8080808080808080 (logior sub ,c))))
       (declare (type (unsigned-byte 64) ,c sub r))
       (sb-c::%primitive swar::fpopcount-boxed r))))

(defmacro utf8-count-fast (chunk)
  (let ((c (gensym "CHUNK")))
    `(let* ((,c ,chunk)
            (shifted (ash ,c 1))
            (cont-mask (logand ,c (lognot shifted) #x8080808080808080))
            (cont-count (sb-c::%primitive swar::fpopcount-unboxed cont-mask)))
       (declare (type (unsigned-byte 64) ,c shifted cont-mask)
                (type fixnum cont-count))
       (the fixnum (- 8 cont-count)))))

(defmacro utf8-count-strict (chunk &optional (prev-ed 0))
  (let ((c (gensym "CHUNK"))
        (p (gensym "PREV-ED")))
    `(let* ((,c ,chunk)
            (,p ,prev-ed)
            (ascii-mask (logand (lognot ,c) #x8080808080808080))
            (lo (logand ,c #x7F7F7F7F7F7F7F7F))
            (ge194 (ldb (byte 64 0) (+ lo #x3E3E3E3E3E3E3E3E)))
            (gt244 (ldb (byte 64 0) (+ lo #x0B0B0B0B0B0B0B0B)))
            (vlead-mask (logand (logandc2 ge194 gt244) ,c #x8080808080808080))
            (valid-starts (logior ascii-mask vlead-mask)))
       (declare (type (unsigned-byte 64) ,c ascii-mask lo ge194 gt244 vlead-mask valid-starts)
                (type (unsigned-byte 8) ,p)
                (ignorable ,p))
       (values (sb-c::%primitive swar::fpopcount-boxed valid-starts) 0))))

;;; swar.cl ends here
