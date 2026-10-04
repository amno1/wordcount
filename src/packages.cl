;; packages.cl
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

(in-package #:cl-user)

;; SB-SIMD-AVX512BW/-AVX512F only exist in an SBCL build whose sb-simd
;; contrib carries the AVX-512 instruction-set additions (mask64,
;; u8.64, u64.8, ...) -- the same #+avx512 feature that gates
;; kernels-assembly-512(-vops).lisp, checked once in wordcount.asd.
;;
;; They're deliberately NOT :USE'd directly: SB-SIMD-AVX512BW/-AVX512F
;; export several names (U8!, ...) that SB-SIMD-AVX2 already inherits
;; from SB-SIMD-AVX. :use-ing both sides of that conflict signals
;; a NAME-CONFLICT at DEFPACKAGE time. Local nicknames only; kernels
;; using U8.64/MASK64/etc.

(defpackage #:wordcount
  (:use #:cl #:with-user-abort #:sb-simd-avx2)
  (:shadow #:debug)
  (:local-nicknames (#:avx2 #:sb-simd-avx2)
                    (#:avx #:sb-simd-avx)
                    (#:sse4.1 #:sb-simd-sse4.1)
                    #+avx512 (#:avx512bw #:sb-simd-avx512bw)
                    #+avx512 (#:avx512f #:sb-simd-avx512f))
  (:nicknames #:wc))

(defpackage #:wc-benchmark
  (:use #:cl)
  (:nicknames #:wcb)
  (:export #:wc-simple #:wc-suite))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *wc-avx512-p*
    #+avx512 t
    #-avx512 nil))

;;; packages.cl ends here
