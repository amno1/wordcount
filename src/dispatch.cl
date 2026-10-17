;; dispatch.cl
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

;; Kernel invocation macro and dispatch logic based on mask and character mode.

;;; Code:

(in-package :wc)

(declaim (optimize (speed 3) (safety 1)))

(defmacro kernel-call (base-name implementation &rest args)
  (let* ((name-string (symbol-name base-name))
         (generic-fn (intern (concatenate 'string name-string "-GENERIC") :wc))
         (avx512-fn  (intern (concatenate 'string name-string "-AVX512")  :wc)))
    `(ecase ,implementation
       (:generic (,generic-fn ,@args))
       (:avx2    ,(if (find :avx2 *features*)
                      `(,base-name ,@args)
                      `(,generic-fn ,@args)))
       (:avx512  ,(cond
                    ((find :avx512 *features*) `(,avx512-fn ,@args))
                    ((find :avx2 *features*) `(,base-name ,@args))
                    (t `(,generic-fn ,@args)))))))

(declaim (inline dispatch-kernel))
(defun dispatch-kernel (implementation dispatch-mask char-mode sap size init-ws &optional (init-ed 0))
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum size)
           (type (unsigned-byte 8) init-ws init-ed)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member nil :chars :chars-strict) char-mode)
           (type (member :generic :avx2 :avx512) implementation))
  (multiple-value-bind (lc wc cc)
      (case dispatch-mask
        (0 nil)
        (7
         (case char-mode
           (:chars-strict (kernel-call count-lines-words-and-chars-utf8-strict implementation sap size init-ws init-ed))
           (:chars        (kernel-call count-lines-words-and-chars-utf8 implementation sap size init-ws))
           (t             (kernel-call count-lines-words-and-chars-ascii implementation sap size init-ws))))
        (1
         (case char-mode
           (:chars-strict (kernel-call count-chars-utf8-strict implementation sap size init-ed))
           (:chars        (kernel-call count-chars-utf8 implementation sap size))
           (t             (kernel-call count-chars-ascii implementation sap size))))
        (2
         (kernel-call count-words-ascii implementation sap size init-ws))
        (3
         (case char-mode
           (:chars-strict (kernel-call count-words-and-chars-utf8-strict implementation sap size init-ws init-ed))
           (:chars        (kernel-call count-words-and-chars-utf8 implementation sap size init-ws))
           (t             (kernel-call count-words-and-chars-ascii implementation sap size init-ws))))
        (4
         (kernel-call count-lines-ascii implementation sap size))
        (5
         (case char-mode
           (:chars-strict (kernel-call count-lines-and-chars-utf8-strict implementation sap size init-ed))
           (:chars        (kernel-call count-lines-and-chars-utf8 implementation sap size))
           (t             (kernel-call count-lines-and-chars-ascii implementation sap size))))
        (6
         (kernel-call count-lines-and-words-ascii implementation sap size init-ws)))
    (values (the fixnum (or lc 0))
            (the fixnum (or wc 0))
            (the fixnum (or cc 0)))))

;;; dispatch.cl ends here
