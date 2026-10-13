;; common.cl
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

;; 

;;; Code:

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

(in-package :sb-posix)

#+unix
(eval-when (:compile-toplevel :load-toplevel :execute)
  (declaim (inline sysconf pread posix-read aligned-alloc alien-free posix-fadvise posix-madvise))

  (define-call "posix_fadvise" int minusp
    (fd file-descriptor) (offset off-t) (size off-t) (advice int))

  (define-call "posix_madvise" int minusp
    (addr sb-sys:system-area-pointer) (length unsigned) (flags int))

  (define-alien-routine sysconf int (name int))

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
  (export 'posix-madvise :sb-posix)
  (export 'posix-fadvise :sb-posix)
  (export 'posix-read :sb-posix)
  (export 'pread :sb-posix)
  (export 'aligned-alloc :sb-posix)
  (export 'alien-free :sb-posix))

(in-package :wc)

(defconstant +default-chunk-size+ (* 1024 1024))

;; Per-lane accumulators in the unrolled kernels. Bounded by the input
;; size, so 60 bits is ample, and summing four of them still fits a
;; FIXNUM -- which keeps the final (+ a0 a1 a2 a3) inline.
(deftype acc-count () '(unsigned-byte 64))

(declaim (ftype (function () (values (integer 1 #.most-positive-fixnum) &optional)) ncpus))
(defun ncpus ()
  (let ((val (sb-posix::sysconf 84)))
    (if (< val 1) 1 val)))

;; Both call sites (WC.CL, MAIN.CL) always pass exactly the 3 flags
;; count-lines/count-words/count-characters, so the result is always
;; in [0,7] -- declared here so callers can open-code ZEROP/CASE on
;; the mask instead of falling back to generic NUMBER comparisons.
(declaim (ftype (function (&rest t) (unsigned-byte 3)) make-dispatch-mask))
(defun make-dispatch-mask (&rest flags)
  "Produces an OR-ed bitmask where each flag corresponds to a bit.
   The first flag provided becomes the most significant bit."
  (the (unsigned-byte 3)
       (reduce (lambda (mask flag)
                 (logior (ash mask 1) (if flag 1 0)))
               flags :initial-value 0)))

;;; common.cl ends here
