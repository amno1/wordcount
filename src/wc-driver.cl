;;; wc-driver.cl
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

;;; High-level CLI driver coordinating file processing and output formatting.

;;; Code:

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 1)))

(defun wc (file-list &key count-lines count-words count-characters count-bytes (char-mode :chars)
                       (implementation :avx2)
                       (number-threads (min 8 (ncpus)))
                       (chunk-size +default-chunk-size+))
  "Process FILE-LIST counting lines, words, characters, and bytes.
   Returns (VALUES RESULTS ANY-ERRORS-P)."
  (let* ((impl (resolve-implementation implementation))
         (dispatch-mask (make-dispatch-mask count-lines
                                            count-words
                                            count-characters))
         (final-results nil)
         (any-errors nil))
    (declare (type (unsigned-byte 3) dispatch-mask)
             (type (member :generic :avx2 :avx512) impl)
             (type fixnum number-threads chunk-size))

    (flet ((format-result (lines words chars bytes path)
             (let (file-results)
               (when count-lines
                 (push lines file-results))
               (when count-words
                 (push words file-results))
               (when count-characters
                 (push chars file-results))
               (when count-bytes
                 (push bytes file-results))
               (nconc (nreverse file-results) (if path (list path) nil)))))

      (if (null file-list)
          ;; Read from STDIN
          (handler-case
              (multiple-value-bind (l w c b err)
                  (process-fd 0 dispatch-mask char-mode impl number-threads chunk-size)
                (if err
                    (progn
                      (format *error-output* "wc: standard input: ~a~%" err)
                      (setf any-errors t))
                    (setf final-results (list (format-result l w c b "")))))
            (error (e)
              (format *error-output* "wc: standard input: ~a~%" e)
              (setf any-errors t)))
          ;; Process each file in file-list
          (dolist (path file-list)
            (declare (type simple-string path))
            (if (string= path "-")
                (handler-case
                    (multiple-value-bind (l w c b err)
                        (process-fd 0 dispatch-mask char-mode impl number-threads chunk-size)
                      (if err
                          (progn
                            (format *error-output* "wc: -: ~a~%" err)
                            (setf any-errors t))
                          (push (format-result l w c b "-") final-results)))
                  (error (e)
                    (format *error-output* "wc: -: ~a~%" e)
                    (setf any-errors t)))
                (handler-case
                    (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
                      (unwind-protect
                           (multiple-value-bind (l w c b err)
                               (process-fd fd dispatch-mask char-mode impl number-threads chunk-size)
                             (if err
                                 (progn
                                   (format *error-output* "wc: ~a: ~a~%" path err)
                                   (setf any-errors t))
                                 (push (format-result l w c b path) final-results)))
                        (sb-posix:close fd)))
                  (sb-posix:syscall-error (e)
                    (format *error-output* "wc: ~a: ~a~%" path
                            (sb-int:strerror (sb-posix:syscall-errno e)))
                    (setf any-errors t))
                  (error (e)
                    (format *error-output* "wc: ~a: ~a~%" path e)
                    (setf any-errors t))))))
      (values (if (null file-list)
                  final-results
                  (nreverse final-results))
              any-errors))))

;;; wc-driver.cl ends here
