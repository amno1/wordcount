;;; api.cl
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

;;; Public counting API:
;;; - Low-level SAP tier (count-*-sap): directly on foreign memory pointers.
;;; - Mid-level FD tier (count-*-fd): multi-threaded or stream processing on file descriptors.
;;; - High-level Path tier (count-*-path): processing filesystem paths.

;;; Code:

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 1)))

(defun resolve-implementation (&optional (requested :auto))
  "REQUESTED is :GENERIC, :AVX2, :AVX512, :AUTO, or NIL (pick the fastest
   implementation this binary was built with). Returns the concrete
   implementation to use, falling back from :AVX512 to :AVX2 (with a warning)
   when this binary has no AVX-512 support."
  (case requested
    ((nil :auto) #+avx512 :avx512 #-avx512 :avx2)
    (:avx512
     #+avx512 :avx512
     #-avx512 (progn
                (format *error-output*
                        "wc: --implementation avx512 requested, but this build has no AVX-512 support -- falling back to avx2~%")
                :avx2))
    (t requested)))


;;; Tier 1: Low-level SAP functions

(defun count-lines-sap (sap size &key (implementation :auto))
  "Count newline characters in SAP buffer."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size))
  (kernel-call count-lines-ascii (resolve-implementation implementation) sap size))

(defun count-words-sap (sap size &key (implementation :auto) (init-ws #xFF))
  "Count whitespace-delimited words in SAP buffer."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws))
  (nth-value 1 (kernel-call count-words-ascii (resolve-implementation implementation) sap size init-ws)))

(defun count-chars-ascii-sap (sap size &key (implementation :auto))
  "Count ASCII characters in SAP buffer."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size))
  (nth-value 2 (kernel-call count-chars-ascii (resolve-implementation implementation) sap size)))

(defun count-chars-utf8-sap (sap size &key (implementation :auto))
  "Count UTF-8 characters (excluding continuation bytes) in SAP buffer."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size))
  (nth-value 2 (kernel-call count-chars-utf8 (resolve-implementation implementation) sap size)))

(defun count-chars-utf8-strict-sap (sap size &key (implementation :auto) (init-ed 0))
  "Count valid UTF-8 characters rejecting surrogate codepoints in SAP buffer."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ed))
  (nth-value 2 (kernel-call count-chars-utf8-strict (resolve-implementation implementation) sap size init-ed)))

(defun count-bytes-sap (sap size)
  "Count bytes in SAP buffer."
  (declare (ignore sap) (type fixnum size))
  size)

(defun count-lines-and-words-sap (sap size &key (implementation :auto) (init-ws #xFF))
  "Count lines and words in SAP buffer. Returns (VALUES LINES WORDS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws))
  (multiple-value-bind (l w)
      (kernel-call count-lines-and-words-ascii (resolve-implementation implementation) sap size init-ws)
    (values l w)))

(defun count-lines-and-chars-ascii-sap (sap size &key (implementation :auto))
  "Count lines and ASCII characters in SAP buffer. Returns (VALUES LINES CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size))
  (multiple-value-bind (l _ c)
      (kernel-call count-lines-and-chars-ascii (resolve-implementation implementation) sap size)
    (declare (ignore _))
    (values l c)))

(defun count-lines-and-chars-utf8-sap (sap size &key (implementation :auto))
  "Count lines and UTF-8 characters in SAP buffer. Returns (VALUES LINES CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size))
  (multiple-value-bind (l _ c)
      (kernel-call count-lines-and-chars-utf8 (resolve-implementation implementation) sap size)
    (declare (ignore _))
    (values l c)))

(defun count-lines-and-chars-utf8-strict-sap (sap size &key (implementation :auto) (init-ed 0))
  "Count lines and strict UTF-8 characters in SAP buffer. Returns (VALUES LINES CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ed))
  (multiple-value-bind (l _ c)
      (kernel-call count-lines-and-chars-utf8-strict (resolve-implementation implementation) sap size init-ed)
    (declare (ignore _))
    (values l c)))

(defun count-words-and-chars-ascii-sap (sap size &key (implementation :auto) (init-ws #xFF))
  "Count words and ASCII characters in SAP buffer. Returns (VALUES WORDS CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws))
  (multiple-value-bind (_ w c)
      (kernel-call count-words-and-chars-ascii (resolve-implementation implementation) sap size init-ws)
    (declare (ignore _))
    (values w c)))

(defun count-words-and-chars-utf8-sap (sap size &key (implementation :auto) (init-ws #xFF))
  "Count words and UTF-8 characters in SAP buffer. Returns (VALUES WORDS CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws))
  (multiple-value-bind (_ w c)
      (kernel-call count-words-and-chars-utf8 (resolve-implementation implementation) sap size init-ws)
    (declare (ignore _))
    (values w c)))

(defun count-words-and-chars-utf8-strict-sap (sap size &key (implementation :auto) (init-ws #xFF) (init-ed 0))
  "Count words and strict UTF-8 characters in SAP buffer. Returns (VALUES WORDS CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws init-ed))
  (multiple-value-bind (_ w c)
      (kernel-call count-words-and-chars-utf8-strict (resolve-implementation implementation) sap size init-ws init-ed)
    (declare (ignore _))
    (values w c)))

(defun count-lines-words-and-chars-ascii-sap (sap size &key (implementation :auto) (init-ws #xFF))
  "Count lines, words, and ASCII characters in SAP buffer. Returns (VALUES LINES WORDS CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws))
  (kernel-call count-lines-words-and-chars-ascii (resolve-implementation implementation) sap size init-ws))

(defun count-lines-words-and-chars-utf8-sap (sap size &key (implementation :auto) (init-ws #xFF))
  "Count lines, words, and UTF-8 characters in SAP buffer. Returns (VALUES LINES WORDS CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws))
  (kernel-call count-lines-words-and-chars-utf8 (resolve-implementation implementation) sap size init-ws))

(defun count-lines-words-and-chars-utf8-strict-sap (sap size &key (implementation :auto) (init-ws #xFF) (init-ed 0))
  "Count lines, words, and strict UTF-8 characters in SAP buffer. Returns (VALUES LINES WORDS CHARS)."
  (declare (type sb-sys:system-area-pointer sap) (type fixnum size) (type (unsigned-byte 8) init-ws init-ed))
  (kernel-call count-lines-words-and-chars-utf8-strict (resolve-implementation implementation) sap size init-ws init-ed))


;;; Tier 2 & 3: FD and Path counters

(defmacro define-fd-counter (name dispatch-mask char-mode return-form)
  `(defun ,name (fd &key (implementation :auto) (number-threads (min 8 (ncpus))) (chunk-size +default-chunk-size+))
     (declare (type fixnum fd number-threads chunk-size))
     (multiple-value-bind (lines words chars bytes err)
         (process-fd fd ,dispatch-mask ,char-mode (resolve-implementation implementation) number-threads chunk-size)
       (declare (ignorable lines words chars bytes err))
       ,return-form)))

(defmacro define-path-counter (name fd-counter return-error-form)
  `(defun ,name (path &key (implementation :auto) (number-threads (min 8 (ncpus))) (chunk-size +default-chunk-size+))
     (if (string= path "-")
         (,fd-counter 0 :implementation implementation
                        :number-threads number-threads
                        :chunk-size chunk-size)
         (handler-case
             (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
               (unwind-protect
                    (,fd-counter fd :implementation implementation
                                    :number-threads number-threads
                                    :chunk-size chunk-size)
                 (sb-posix:close fd)))
           (error (e)
             ,return-error-form)))))

;; 1. Lines
(define-fd-counter count-lines-fd 4 nil (values lines bytes err))
(define-path-counter count-lines-path count-lines-fd (values 0 0 e))
(defun count-lines (path &key (implementation :auto) (number-threads (min 8 (ncpus))) (chunk-size +default-chunk-size+))
  (count-lines-path path :implementation implementation :number-threads number-threads :chunk-size chunk-size))

;; 2. Words
(define-fd-counter count-words-fd 2 nil (values words bytes err))
(define-path-counter count-words-path count-words-fd (values 0 0 e))
(defun count-words (path &key (implementation :auto) (number-threads (min 8 (ncpus))) (chunk-size +default-chunk-size+))
  (count-words-path path :implementation implementation :number-threads number-threads :chunk-size chunk-size))

;; 3. Chars ASCII
(define-fd-counter count-chars-ascii-fd 1 nil (values chars bytes err))
(define-path-counter count-chars-ascii-path count-chars-ascii-fd (values 0 0 e))

;; 4. Chars UTF-8
(define-fd-counter count-chars-utf8-fd 1 :chars (values chars bytes err))
(define-path-counter count-chars-utf8-path count-chars-utf8-fd (values 0 0 e))

;; 5. Chars UTF-8 Strict
(define-fd-counter count-chars-utf8-strict-fd 1 :chars-strict (values chars bytes err))
(define-path-counter count-chars-utf8-strict-path count-chars-utf8-strict-fd (values 0 0 e))

;; 6. Bytes
(define-fd-counter count-bytes-fd 0 nil (values bytes err))
(define-path-counter count-bytes-path count-bytes-fd (values 0 e))
(defun count-bytes (path &key (implementation :auto) (number-threads (min 8 (ncpus))) (chunk-size +default-chunk-size+))
  (count-bytes-path path :implementation implementation :number-threads number-threads :chunk-size chunk-size))

;; 7. Lines and Words
(define-fd-counter count-lines-and-words-fd 6 nil (values lines words bytes err))
(define-path-counter count-lines-and-words-path count-lines-and-words-fd (values 0 0 0 e))
(defun count-lines-and-words (path &key (implementation :auto) (number-threads (min 8 (ncpus))) (chunk-size +default-chunk-size+))
  (count-lines-and-words-path path :implementation implementation :number-threads number-threads :chunk-size chunk-size))

;; 8. Lines and Chars ASCII
(define-fd-counter count-lines-and-chars-ascii-fd 5 nil (values lines chars bytes err))
(define-path-counter count-lines-and-chars-ascii-path count-lines-and-chars-ascii-fd (values 0 0 0 e))

;; 9. Lines and Chars UTF-8
(define-fd-counter count-lines-and-chars-utf8-fd 5 :chars (values lines chars bytes err))
(define-path-counter count-lines-and-chars-utf8-path count-lines-and-chars-utf8-fd (values 0 0 0 e))

;; 10. Lines and Chars UTF-8 Strict
(define-fd-counter count-lines-and-chars-utf8-strict-fd 5 :chars-strict (values lines chars bytes err))
(define-path-counter count-lines-and-chars-utf8-strict-path count-lines-and-chars-utf8-strict-fd (values 0 0 0 e))

;; 11. Words and Chars ASCII
(define-fd-counter count-words-and-chars-ascii-fd 3 nil (values words chars bytes err))
(define-path-counter count-words-and-chars-ascii-path count-words-and-chars-ascii-fd (values 0 0 0 e))

;; 12. Words and Chars UTF-8
(define-fd-counter count-words-and-chars-utf8-fd 3 :chars (values words chars bytes err))
(define-path-counter count-words-and-chars-utf8-path count-words-and-chars-utf8-fd (values 0 0 0 e))

;; 13. Words and Chars UTF-8 Strict
(define-fd-counter count-words-and-chars-utf8-strict-fd 3 :chars-strict (values words chars bytes err))
(define-path-counter count-words-and-chars-utf8-strict-path count-words-and-chars-utf8-strict-fd (values 0 0 0 e))

;; 14. Lines, Words, and Chars ASCII
(define-fd-counter count-lines-words-and-chars-ascii-fd 7 nil (values lines words chars bytes err))
(define-path-counter count-lines-words-and-chars-ascii-path count-lines-words-and-chars-ascii-fd (values 0 0 0 0 e))

;; 15. Lines, Words, and Chars UTF-8
(define-fd-counter count-lines-words-and-chars-utf8-fd 7 :chars (values lines words chars bytes err))
(define-path-counter count-lines-words-and-chars-utf8-path count-lines-words-and-chars-utf8-fd (values 0 0 0 0 e))

;; 16. Lines, Words, and Chars UTF-8 Strict
(define-fd-counter count-lines-words-and-chars-utf8-strict-fd 7 :chars-strict (values lines words chars bytes err))
(define-path-counter count-lines-words-and-chars-utf8-strict-path count-lines-words-and-chars-utf8-strict-fd (values 0 0 0 0 e))

;;; api.cl ends here
