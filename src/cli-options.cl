;; cli-options.cl
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

;;; Code:

(in-package :wc)

(defconstant +min-chunk-size+ (* 1024))             ; 1 KB
(defconstant +max-chunk-size+ (* 1024 1024 1024))   ; 1 GB
(defconstant +default-chunk-size+ (* 1024 1024))     ; 1 MB (optimal L2 cache size)

(defun parse-cli-integer (string min max option-name)
  "Parse STRING as an integer, ensure it lies in [MIN, MAX].
   On failure, print an error and exit."
  (handler-case
      (let ((n (parse-integer string :junk-allowed nil)))
        (unless (<= min n max)
          (print-help-and-quit "~a must be between ~a and ~a"
                               option-name min max))
        n)
    (error ()
      (print-help-and-quit "~a must be an integer" option-name))))

(defun resolve-implementation (requested)
  "REQUESTED is :GENERIC, :AVX2, :AVX512, or NIL (pick the fastest
   implementation this binary was built with). Returns the concrete
   implementation WC.CL should actually use, falling back from :AVX512
   to :AVX2 (with a warning) when this binary has no AVX-512 support."
  (case requested
    ((nil) #+avx512 :avx512 #-avx512 :avx2)
    (:avx512
     #+avx512 :avx512
     #-avx512 (progn
                (format *error-output*
                        "wc: --implementation avx512 requested, but this build has no AVX-512 support -- falling back to avx2~%")
                :avx2))
    (t requested)))

(defun read-files0-from (filename)
  "Read NUL-terminated filenames from a file or stdin."
  (declare (type simple-string filename))
  (let ((files nil)
        (path-bytes (make-array 1024 :element-type '(unsigned-byte 8) :fill-pointer 0 :adjustable t)))
    (flet ((process-stream (stream)
             (loop for byte = (read-byte stream nil nil)
                   while byte
                   do (if (zerop byte)
                          (unless (zerop (length path-bytes))
                            (push (sb-ext:octets-to-string path-bytes :external-format :utf-8) files)
                            (setf (fill-pointer path-bytes) 0))
                          (vector-push-extend byte path-bytes)))))
      (if (string= filename "-")
          (let ((stdin-bin (sb-sys:make-fd-stream
                            0 :input t :element-type '(unsigned-byte 8) :buffering :full)))
            (process-stream stdin-bin))
          (with-open-file (stream filename :direction :input :element-type '(unsigned-byte 8))
            (process-stream stream))))
    (nreverse files)))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *wc-options*
    '(("l" "lines")
      ("w" "words")
      ("c" "bytes")
      ("m" "chars")
      ("-" "stdin")
      "files0-from"
      "utf8-strict"
      "implementation"
      "debug"
      "help"
      "version"
      "total" "auto" "always" "never" "only"
      "generic" "avx2" "avx512"
      "chunk-size"
      "number-threads")))

(defun print-help ()
  (format t "Usage: wc [OPTION]... [FILE]...
Print newline, word, and byte counts for each FILE.

Options:
  -c, --bytes            print the byte counts
  -m, --chars            print the character counts (UTF-8)
  -l, --lines            print the newline counts
  -w, --words            print the word counts
      --utf8-strict      enable strict UTF-8 character validation
      --implementation=X select the counting kernel: generic, avx2, or
                         avx512 (default: the fastest one this binary
                         was built with)
      --debug            print which implementation was used
      --chunk-size=BYTES set read buffer size for counting (1 KB – 1 GB,
                         default 1 MB)
      --number-threads=N use N worker threads (1 – number of CPU cores,
                         default 1)
      --help             display this help and exit
      --version          print program version
"))

(defun print-version ()
  (format t "Wordcount version: 0.1.0 by A. Miller~%"))

(defun print-help-and-quit (format-string &rest args)
  (terpri)
  (apply #'format t format-string args)
  (terpri)
  (print-help)
  (terpri)
  (sb-ext:quit))

;;; cli-options.cl ends here
