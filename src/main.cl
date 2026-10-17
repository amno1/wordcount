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

(defun main ()
  (handler-case
      (with-user-abort
        (let* ((cfg (parse-cli-args (rest sb-ext:*posix-argv*)))
               (files (cli-config-files cfg))
               (raw-lines (cli-config-count-lines cfg))
               (raw-words (cli-config-count-words cfg))
               (raw-chars (cli-config-count-chars cfg))
               (raw-bytes (cli-config-count-bytes cfg))
               (default-p (not (or raw-lines raw-words raw-chars raw-bytes)))
               (count-lines (or default-p raw-lines))
               (count-words (or default-p raw-words))
               (count-chars raw-chars)
               (count-bytes (or default-p raw-bytes))
               (char-mode (if (cli-config-utf8-strict cfg)
                              :chars-strict
                              (if count-chars :chars nil)))
               (implementation (cli-config-implementation cfg))
               (debug (cli-config-debug cfg))
               (chunk-size (cli-config-chunk-size cfg))
               (number-threads (cli-config-number-threads cfg))
               (print-per-file (cli-config-print-per-file cfg))
               (print-total (case (cli-config-total-mode cfg)
                              (:always t)
                              (:only t)
                              (:never nil)
                              (:auto (> (length files) 1))
                              (t nil)))
               (exit-code 0))

          ;; If --files0-from was supplied and yielded no files, do not read from stdin.
          (when (and (null files) (cli-config-files0-from-supplied-p cfg))
            (sb-ext:exit :code 0))

          (unwind-protect
               (progn
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
                                 :debug debug)

                     (when any-errors
                       (setf exit-code 1))

                     (dolist (file-result results)
                       (let ((counts (butlast file-result))
                             (path (car (last file-result))))

                         (when print-per-file
                           (dolist (count counts)
                             (format t "~8d " count))
                           (if (zerop (length path))
                               (terpri)
                               (format t " ~a~%" path)))

                         (when count-lines (incf lines (the fixnum (pop counts))))
                         (when count-words (incf words (the fixnum (pop counts))))
                         (when count-chars (incf chars (the fixnum (pop counts))))
                         (when count-bytes (incf bytes (the fixnum (pop counts))))))

                     (when print-total
                       (when count-lines (format t "~8d " lines))
                       (when count-words (format t "~8d " words))
                       (when count-chars (format t "~8d " chars))
                       (when count-bytes (format t "~8d " bytes))
                       (format t " total~%")))))

            (shutdown-worker-pool))

          (sb-ext:exit :code exit-code)))

    (user-abort ()
      (terpri)
      (shutdown-worker-pool)
      (sb-ext:exit :code 130))
    (error (e)
      (format *error-output* "wc: ~a~%" e)
      (shutdown-worker-pool)
      (sb-ext:exit :code 1)))
  (sb-ext:exit :code 0))

;;; main.cl ends here
