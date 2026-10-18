;; main.cl
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

(defun quote-file-name (name)
  "Quote filenames containing newlines using shell $'\\n' escaping, matching GNU wc."
  (if (find #\Newline name)
      (let ((parts nil)
            (start 0))
        (loop for pos = (position #\Newline name :start start)
              while pos
              do (push (subseq name start pos) parts)
                 (setf start (1+ pos)))
        (push (subseq name start) parts)
        (format nil "'~{~a~^'$'\\n''~}'" (nreverse parts)))
      name))

(defun print-count-line (counts path number-width)
  "Print a single line of counts formatted to match GNU wc."
  (when counts
    (format t "~vd" number-width (first counts))
    (dolist (c (rest counts))
      (format t " ~vd" number-width c))
    (when (and path (> (length path) 0))
      (format t " ~a" (quote-file-name path)))
    (terpri)))

(defun compute-number-width (files n-counters total-mode files0-from-pipe-p files0-from-supplied-p)
  "Compute field width for counts according to GNU wc rules."
  (cond
    ((eq total-mode :only) 1)
    (files0-from-pipe-p 1)
    ((or (null files) (zerop (length files)))
     (if (or files0-from-supplied-p (= n-counters 1)) 1 7))
    ((and (= (length files) 1) (= n-counters 1))
     1)
    (t
     (let ((minimum-width 1)
           (regular-total 0))
       (dolist (file files)
         (cond
           ((or (null file) (string= file "-"))
            (setf minimum-width 7))
           (t
            (let ((st (ignore-errors (sb-posix:stat file))))
              (when st
                (if (sb-posix:s-isreg (sb-posix:stat-mode st))
                    (incf regular-total (sb-posix:stat-size st))
                    (setf minimum-width 7)))))))
       (let ((width 1))
         (loop while (>= regular-total 10) do
           (incf width)
           (setf regular-total (floor regular-total 10)))
         (max width minimum-width))))))

(defun main ()
  (handler-case
      (with-user-abort
        (let* ((cfg (parse-cli-args (rest sb-ext:*posix-argv*)))
               (files (cli-config-files cfg))
               (from-supplied-p (cli-config-files0-from-supplied-p cfg))
               (from-count (cli-config-files0-from-count cfg))
               (from-pipe-p (and from-supplied-p (cli-config-files0-from-pipe-p cfg)))
               (from-err (cli-config-files0-from-err cfg))
               (raw-lines (cli-config-count-lines cfg))
               (raw-words (cli-config-count-words cfg))
               (raw-chars (cli-config-count-chars cfg))
               (raw-bytes (cli-config-count-bytes cfg))
               (default-p (not (or raw-lines raw-words raw-chars raw-bytes)))
               (count-lines (or default-p raw-lines))
               (count-words (or default-p raw-words))
               (count-chars raw-chars)
               (count-bytes (or default-p raw-bytes))
               (n-counters (+ (if count-lines 1 0)
                              (if count-words 1 0)
                              (if count-chars 1 0)
                              (if count-bytes 1 0)))
               (char-mode (if (cli-config-utf8-strict cfg)
                              :chars-strict
                              (if count-chars :chars nil)))
               (implementation (cli-config-implementation cfg))
               (debug (cli-config-debug cfg))
               (chunk-size (cli-config-chunk-size cfg))
               (number-threads (cli-config-number-threads cfg))
               (number-width (compute-number-width files n-counters (cli-config-total-mode cfg) from-pipe-p from-supplied-p))
               (print-per-file (cli-config-print-per-file cfg))
               (print-total (case (cli-config-total-mode cfg)
                              (:always t)
                              (:only t)
                              (:never nil)
                              (:auto (if from-supplied-p
                                         (> from-count 1)
                                         (> (length files) 1)))
                              (t nil)))
               (exit-code (if from-err 1 0))
               (multiple-files (and files (cdr files))))

          ;; If --files0-from was supplied and yielded no files, handle total and exit.
          (when (and (null files) from-supplied-p)
            (when print-total
              (let ((counts nil))
                (when count-lines (push 0 counts))
                (when count-words (push 0 counts))
                (when count-chars (push 0 counts))
                (when count-bytes (push 0 counts))
                (print-count-line (nreverse counts)
                                  (if (eq (cli-config-total-mode cfg) :only) nil "total")
                                  number-width)))
            (finish-output)
            (sb-ext:exit :code exit-code :abort t))

          (when (> number-threads 1)
            (ensure-worker-pool number-threads chunk-size))

          (let ((lines 0) (words 0) (chars 0) (bytes 0))
            (multiple-value-bind (results any-errors)
                (wc files :count-lines count-lines
                          :count-words count-words
                          :count-characters count-chars
                          :count-bytes count-bytes
                          :char-mode char-mode
                          :implementation implementation
                          :number-threads number-threads
                          :chunk-size chunk-size
                          :debug debug
                          :close-fd (or multiple-files from-supplied-p))

              (when any-errors
                (setf exit-code 1))

              (dolist (file-result results)
                (let ((counts (butlast file-result))
                      (path (car (last file-result))))

                  (when print-per-file
                    (print-count-line counts path number-width))

                  (let ((c counts))
                    (when count-lines (incf lines (the fixnum (pop c))))
                    (when count-words (incf words (the fixnum (pop c))))
                    (when count-chars (incf chars (the fixnum (pop c))))
                    (when count-bytes (incf bytes (the fixnum (pop c)))))))

              (when print-total
                (let ((counts nil))
                  (when count-lines (push lines counts))
                  (when count-words (push words counts))
                  (when count-chars (push chars counts))
                  (when count-bytes (push bytes counts))
                  (print-count-line (nreverse counts)
                                    (if (eq (cli-config-total-mode cfg) :only) nil "total")
                                    number-width)))))

          (finish-output)
          (sb-ext:exit :code exit-code :abort t)))

    (user-abort ()
      (terpri)
      (finish-output)
      (sb-ext:exit :code 130 :abort t))
    (error (e)
      (format *error-output* "wc: ~a~%" e)
      (finish-output *error-output*)
      (sb-ext:exit :code 1 :abort t)))
  (sb-ext:exit :code 0 :abort t))

;;; main.cl ends here
