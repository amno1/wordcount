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
(defconstant +max-number-threads+ 1024)
;; +default-chunk-size+ is defined in common.cl

(defstruct (cli-config (:copier nil))
  (files nil :type list)
  (files0-from-file nil)
  (files0-from-supplied-p nil :type boolean)
  (files0-from-count 0 :type fixnum)
  (files0-from-err nil :type boolean)
  (files0-from-pipe-p nil :type boolean)
  (count-lines nil :type boolean)
  (count-words nil :type boolean)
  (count-chars nil :type boolean)
  (count-bytes nil :type boolean)
  (utf8-strict nil :type boolean)
  (total-mode :auto)               ; :auto, :always, :never, :only
  (print-per-file t :type boolean)
  (implementation nil)
  (debug nil :type boolean)
  (chunk-size +default-chunk-size+ :type fixnum)
  (number-threads (min 8 (ncpus)) :type fixnum))

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


(defun read-files0-from (filename)
  "Read NUL-terminated filenames from a file or stdin."
  (multiple-value-bind (files err-p n-tokens pipe-p)
      (read-files0-from-spec filename)
    (declare (ignore err-p n-tokens pipe-p))
    files))

(defun read-files0-from-spec (from-file)
  "Read NUL-terminated filenames from FROM-FILE or stdin.
Returns (VALUES FILES ERR-P N-TOKENS PIPE-P)."
  (let ((stream nil)
        (fd nil)
        (pipe-p nil)
        (files nil)
        (err-p nil)
        (n-tokens 0)
        (path-bytes (make-array 1024 :element-type '(unsigned-byte 8) :fill-pointer 0 :adjustable t)))
    (if (string= from-file "-")
        (let ((st (ignore-errors (sb-posix:fstat 0))))
          (setf pipe-p (not (and st (sb-posix:s-isreg (sb-posix:stat-mode st)))))
          (setf stream (sb-sys:make-fd-stream 0 :input t :element-type '(unsigned-byte 8) :buffering :full)))
        (handler-case
            (setf fd (sb-posix:open from-file sb-posix:o-rdonly)
                  stream (sb-sys:make-fd-stream fd :input t :element-type '(unsigned-byte 8) :buffering :full))
          (sb-posix:syscall-error (e)
            (format *error-output* "wc: cannot open '~a' for reading: ~a~%"
                    from-file (sb-int:strerror (sb-posix:syscall-errno e)))
            (sb-ext:exit :code 1 :abort t))
          (error (e)
            (format *error-output* "wc: cannot open '~a' for reading: ~a~%" from-file e)
            (sb-ext:exit :code 1 :abort t))))
    (unwind-protect
         (loop for byte = (read-byte stream nil nil)
               while byte
               do (if (zerop byte)
                      (progn
                        (incf n-tokens)
                        (if (zerop (length path-bytes))
                            (progn
                              (format *error-output* "wc: ~a:~d: invalid zero-length file name~%"
                                      from-file n-tokens)
                              (setf err-p t))
                            (let ((path-str (sb-ext:octets-to-string path-bytes :external-format :utf-8)))
                              (setf (fill-pointer path-bytes) 0)
                              (if (and (string= from-file "-") (string= path-str "-"))
                                  (progn
                                    (format *error-output* "wc: when reading file names from standard input, no file name of '-' allowed~%")
                                    (setf err-p t))
                                  (push path-str files)))))
                      (vector-push-extend byte path-bytes))
               finally
                  (when (> (length path-bytes) 0)
                    (incf n-tokens)
                    (let ((path-str (sb-ext:octets-to-string path-bytes :external-format :utf-8)))
                      (if (and (string= from-file "-") (string= path-str "-"))
                          (progn
                            (format *error-output* "wc: when reading file names from standard input, no file name of '-' allowed~%")
                            (setf err-p t))
                          (push path-str files)))))
      (when fd
        (ignore-errors (close stream))))
    (values (nreverse files) err-p n-tokens pipe-p)))

(defun parse-cli-args (argv)
  "Parse command-line arguments ARGV (excluding argv[0]).
   Returns a populated CLI-CONFIG structure."
  (let ((config (make-cli-config))
        (args argv))
    (loop while args do
      (let ((arg (pop args)))
        (cond
          ;; 1. '--' signals end of options; all subsequent tokens are filenames
          ((string= arg "--")
           (dolist (a args)
             (push a (cli-config-files config)))
           (return))

          ;; 2. '-' represents standard input
          ((string= arg "-")
           (push "-" (cli-config-files config)))

          ;; 3. Long options: '--opt' or '--opt=val'
          ((and (> (length arg) 2)
                (char= (char arg 0) #\-)
                (char= (char arg 1) #\-))
           (let* ((eq-pos (position #\= arg :start 2))
                  (opt (if eq-pos (subseq arg 2 eq-pos) (subseq arg 2)))
                  (val (if eq-pos (subseq arg (1+ eq-pos)) nil)))
             (flet ((require-val ()
                      (or val
                          (pop args)
                          (print-help-and-quit "--~a requires an argument" opt)))
                    (reject-val ()
                      (when val
                        (print-help-and-quit "Option '--~a' does not accept an argument" opt))))
               (cond
                 ((string= opt "lines")        (reject-val) (setf (cli-config-count-lines config) t))
                 ((string= opt "words")        (reject-val) (setf (cli-config-count-words config) t))
                 ((string= opt "bytes")        (reject-val) (setf (cli-config-count-bytes config) t))
                 ((string= opt "chars")        (reject-val) (setf (cli-config-count-chars config) t))
                 ((string= opt "utf8-strict")  (reject-val) (setf (cli-config-count-chars config) t
                                                                  (cli-config-utf8-strict config) t))
                 ((string= opt "debug")        (reject-val) (setf (cli-config-debug config) t))
                 ((string= opt "help")         (reject-val) (print-help) (sb-ext:exit :code 0))
                 ((string= opt "version")      (reject-val) (print-version) (sb-ext:exit :code 0))

                 ((string= opt "chunk-size")
                  (setf (cli-config-chunk-size config)
                        (parse-cli-integer (require-val)
                                           +min-chunk-size+
                                           +max-chunk-size+
                                           "--chunk-size")))

                 ((string= opt "number-threads")
                  (setf (cli-config-number-threads config)
                        (parse-cli-integer (require-val)
                                           1
                                           +max-number-threads+
                                           "--number-threads")))

                 ((string= opt "implementation")
                  (let ((impl-str (require-val)))
                    (setf (cli-config-implementation config)
                          (cond
                            ((string-equal impl-str "generic") :generic)
                            ((string-equal impl-str "avx2")    :avx2)
                            ((string-equal impl-str "avx512")  :avx512)
                            (t (print-help-and-quit
                                "Unknown implementation: ~a (must be generic, avx2, or avx512)"
                                impl-str))))))

                 ((string= opt "total")
                  (let ((tot-str (require-val)))
                    (cond
                      ((string-equal tot-str "auto")   (setf (cli-config-total-mode config) :auto))
                      ((string-equal tot-str "always") (setf (cli-config-total-mode config) :always))
                      ((string-equal tot-str "never")  (setf (cli-config-total-mode config) :never))
                      ((string-equal tot-str "only")   (setf (cli-config-total-mode config) :only))
                      (t (print-help-and-quit
                          "Unknown total mode: ~a (must be auto, always, only, or never)"
                          tot-str)))))

                 ((string= opt "files0-from")
                  (setf (cli-config-files0-from-supplied-p config) t)
                  (setf (cli-config-files0-from-file config) (require-val)))

                 (t (print-help-and-quit "Unknown option: --~a" opt))))))

          ;; 4. Clustered short options: '-lwc', '-m', etc.
          ((and (> (length arg) 1) (char= (char arg 0) #\-))
           (loop for i from 1 below (length arg)
                 for c = (char arg i) do
                   (case c
                     (#\l (setf (cli-config-count-lines config) t))
                     (#\w (setf (cli-config-count-words config) t))
                     (#\c (setf (cli-config-count-bytes config) t))
                     (#\m (setf (cli-config-count-chars config) t))
                     (otherwise (print-help-and-quit "Unknown option: -~c" c)))))

          ;; 5. Positional arguments (filenames)
          (t (push arg (cli-config-files config))))))

    (if (cli-config-files0-from-supplied-p config)
        (progn
          (when (cli-config-files config)
            (format *error-output* "wc: extra operand '~a'~%file operands cannot be combined with --files0-from~%Try 'wc --help' for more information.~%"
                    (first (nreverse (cli-config-files config))))
            (sb-ext:exit :code 1 :abort t))
          (multiple-value-bind (files err-p n-tokens pipe-p)
              (read-files0-from-spec (cli-config-files0-from-file config))
            (setf (cli-config-files config) files
                  (cli-config-files0-from-err config) err-p
                  (cli-config-files0-from-count config) n-tokens
                  (cli-config-files0-from-pipe-p config) pipe-p)))
        (setf (cli-config-files config) (nreverse (cli-config-files config))))
    (setf (cli-config-print-per-file config)
          (not (eq (cli-config-total-mode config) :only)))
    config))

(defun print-help (&optional (stream *standard-output*))
  (format stream "Usage: wc [OPTION]... [FILE]...
Print newline, word, character, and byte counts for each FILE.

Options:
  -c, --bytes            print the byte counts
  -m, --chars            print the character counts (UTF-8)
  -l, --lines            print the newline counts
  -w, --words            print the word counts
      --utf8-strict      enable strict UTF-8 character validation
      --implementation=X select counting kernel: generic, avx2, or avx512
      --debug            print which implementation was used
      --chunk-size=BYTES set read buffer size (1 KB – 1 GB, default 1 MB)
      --number-threads=N use N worker threads (default: min(8, CPU cores))
      --total=WHEN       when to print total: auto, always, only, never
      --files0-from=F    read input from NUL-terminated filenames in F
      --help             display this help and exit
      --version          print program version

Values for options taking arguments can be given as --option=VALUE or --option VALUE.
"))

(defun print-version (&optional (stream *standard-output*))
  (format stream "Wordcount version: 0.1.0 by A. Miller~%"))

(defun print-help-and-quit (format-string &rest args)
  (terpri *error-output*)
  (apply #'format *error-output* format-string args)
  (terpri *error-output*)
  (print-help *error-output*)
  (terpri *error-output*)
  (sb-ext:exit :code 1))

;;; cli-options.cl ends here
