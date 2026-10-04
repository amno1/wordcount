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

;; The real work is done by wc defun, here is just command line parsing
;; and dispatch to the driver to execute what user asks from. It looks
;; more complicated than it is. I was experimenting with writing my own
;; command-line options parser which I meant to use as a standalone
;; library, but I am not done with it. It was another learning project,
;; like everything else here. I am re-using parts from that project here
;; for the test purpose and to learn more. Yes, I am aware of clone,
;; klingon and probably every other option parser in Common Lisp
;; ecostytem. The subject is a regression, but I guess a "custom command
;; line parser" will raise an eybrow or two, so I am mentioning it here
;; for that reason. Everything here is basically just a summary of
;; multiple experiments and learning projects I have on my drive.

;;; Code:

(in-package :wc)

(defun main ()
  (handler-case
      (with-user-abort
        (let ((args (rest sb-ext:*posix-argv*))
              (files nil)
              ;;(workers nil)
              (count-lines nil)
              (count-words nil)
              (count-chars nil)
              (print-total nil)
              (print-per-file t)
              (utf8 nil)
              (implementation nil)
              (debug nil)
              (chunk-size +default-chunk-size+)
              (number-threads (min 8 (ncpus))))
          (declare (type list files))

          (with-cli-parsing (args *wc-options* :min-args 0)
            (:l (setf count-lines t))
            (:w (setf count-words t))
            (:c (setf count-chars t))
            (:m (setf count-chars t utf8 t))
            (:utf8-strict (setf count-chars t utf8 'strict))
            (:chunk-size
             (let ((val (pop args)))
               (if val
                   (setf chunk-size
                         (parse-cli-integer val
                                            +min-chunk-size+
                                            +max-chunk-size+
                                            "--chunk-size"))
                   (print-help-and-quit "--chunk-size requires an argument"))))
            (:number-threads
             (let ((val (pop args)))
               (if val
                   (setf number-threads
                         (parse-cli-integer val
                                            1
                                            (ncpus)
                                            "--number-threads"))
                   (print-help-and-quit "--number-threads requires an argument"))))
            (:debug (setf debug t))
            (:implementation
             (let ((val (pop args)))
               (if (not val)
                   (print-help-and-quit "--implementation requires generic, avx2, or avx512")
                   (locally (declare (type simple-string val))
                     (setf implementation
                           (case (match-option val)
                             (:generic :generic)
                             (:avx2    :avx2)
                             (:avx512  :avx512)
                             (t (print-help-and-quit "Unknown implementation: ~a" val))))))))
            (:help    (print-help)    (sb-ext:exit))
            (:version (print-version) (sb-ext:exit))
            ((or :- :stdin) (push "-" files))
            (:arg (push arg files))
            (:files0-from
             (let ((val (pop args)))
               (if val
                   (dolist (f (read-files0-from val))
                     (push f files))
                   (print-help-and-quit "--files0-from requires an argument"))))
            (:total
             (let ((val (pop args)))
               (if (not val)
                   (print-help-and-quit "--total requires auto, always, only, or never")
                   (locally (declare (type simple-string val))
                     (setf print-total
                           (case (match-option val)
                             (:always t)
                             (:only   (setf print-per-file nil) t)
                             (:never  nil)
                             (:auto   (> (length files) 1))
                             (t (print-help-and-quit "Unknown total mode: ~a" val)))))))))

          (setf implementation (resolve-implementation implementation))
          (when debug
            (format *error-output* "wc: using ~(~a~) implementation~%"
                    implementation))

          ;; Threads managed directly per file
          (let* ((files (nreverse files))
                 (mask (make-dispatch-mask count-lines count-words count-chars))
                 (active-mask (if (zerop mask)
                                  7
                                  mask))
                 (results (wc files :count-lines count-lines
                                    :count-words count-words
                                    :count-characters count-chars
                                    :utf8 utf8
                                    :implementation implementation
                                    :number-threads number-threads
                                    :chunk-size chunk-size))
                 (lines 0) (words 0) (chars 0))
            (declare (type (unsigned-byte 3) mask active-mask))

            (dolist (file-result results)
              (let ((counts (butlast file-result))
                    (path (car (last file-result))))

                (when print-per-file
                  (dolist (count counts)
                    (format t "~8d " count))
                  (format t " ~a~%" path))

                (when (logbitp 2 active-mask)
                  (incf lines (the fixnum (pop counts))))
                (when (logbitp 1 active-mask)
                  (incf words (the fixnum (pop counts))))
                (when (logbitp 0 active-mask)
                  (incf chars (the fixnum (pop counts))))))

            (when print-total
              (when (logbitp 2 active-mask) (format t "~8d " lines))
              (when (logbitp 1 active-mask) (format t "~8d " words))
              (when (logbitp 0 active-mask) (format t "~8d " chars))
              (format t " total~%")))))

    (user-abort ()
      (terpri)
      (sb-ext:exit)))
  (sb-ext:exit))

;;; main.cl ends here
