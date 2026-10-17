;; wc-driver.cl
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

;; High-performance wordcount driver.
;; Coordinates single-threaded linear stream reads and multi-threaded
;; pread chunked reads across seekable files.

;;; Code:

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 1)))

(defun wc-fd-linear (fd dispatch-mask char-mode implementation &optional (buf-size +default-chunk-size+))
  (declare (type fixnum fd buf-size)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member nil :bytes :chars :chars-strict) char-mode)
           (type (member :generic :avx2 :avx512) implementation))
  (let* ((actual-buf-size (max 64 buf-size))
         (alloc-size (round-up-64 (+ actual-buf-size 64)))
         (raw (sb-posix:aligned-alloc 64 alloc-size))
         (buf-sap (sb-sys:sap+ raw 64))
         (prev-ws #xFF)
         (prev-ed 0)
         (t-lines 0)
         (t-words 0)
         (t-chars 0)
         (t-bytes 0))
    (declare (type fixnum t-lines t-words t-chars t-bytes actual-buf-size alloc-size)
             (type (unsigned-byte 8) prev-ws prev-ed)
             (type sb-sys:system-area-pointer raw buf-sap))
    (unwind-protect
         (loop
           (let ((n (the fixnum (sb-posix:posix-read fd buf-sap actual-buf-size))))
             (when (<= n 0) (return))
             (incf t-bytes n)
             (when (> dispatch-mask 0)
               (multiple-value-bind (l w c)
                   (dispatch-kernel implementation dispatch-mask char-mode buf-sap n prev-ws prev-ed)
                 (incf t-lines l)
                 (incf t-words w)
                 (incf t-chars c)
                 (let ((last-b (sb-sys:sap-ref-8 buf-sap (1- n))))
                   (setf prev-ws (if (or (= last-b 32) (<= 9 last-b 13)) #xFF #x00)
                         prev-ed (if (= last-b #xED) 1 0)))))))
      (sb-posix:alien-free raw))
    (values t-lines t-words t-chars t-bytes nil)))

(defun wc-fd (fd dispatch-mask char-mode implementation nthreads &optional (buf-size +default-chunk-size+))
  (declare (type fixnum fd nthreads buf-size)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member nil :bytes :chars :chars-strict) char-mode)
           (type (member :generic :avx2 :avx512) implementation))
  (let* ((cur (ignore-errors (sb-posix:lseek fd 0 sb-posix:seek-cur)))
         (end (ignore-errors (sb-posix:lseek fd 0 sb-posix:seek-end))))
    (cond
      ;; Seekable regular file
      ((and cur end (>= cur 0) (>= end 0) (> end cur))
       (let ((size (- end cur)))
         (declare (type fixnum size))
         ;; Fast path: if dispatch-mask is 0, we only care about bytes and file size is known!
         (if (zerop dispatch-mask)
             (values 0 0 0 size nil)
             (progn
               (sb-posix:lseek fd cur sb-posix:seek-set)
               (if (or (<= nthreads 1) (< size (* 8 1024 1024)))
                   (wc-fd-linear fd dispatch-mask char-mode implementation buf-size)
                   (wc-fd-mt fd size nthreads dispatch-mask char-mode implementation buf-size))))))
      ;; Empty file
      ((and cur end (= cur end))
       (values 0 0 0 0 nil))
      ;; Non-seekable stream (stdin, pipes, sockets)
      (t
       (wc-fd-linear fd dispatch-mask char-mode implementation buf-size)))))

(defun wc (file-list &key count-lines count-words count-characters count-bytes (char-mode :chars)
                       (implementation :avx2)
                       (number-threads (min 8 (ncpus)))
                       (chunk-size +default-chunk-size+))
  "Process FILE-LIST counting lines, words, characters, and bytes.
   Returns (VALUES RESULTS ANY-ERRORS-P)."
  (let ((dispatch-mask (make-dispatch-mask count-lines
                                          count-words
                                          count-characters))
        (final-results nil)
        (any-errors nil))
    (declare (type (unsigned-byte 3) dispatch-mask)
              (type (member :generic :avx2 :avx512) implementation)
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
                  (wc-fd 0 dispatch-mask char-mode implementation number-threads chunk-size)
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
                        (wc-fd 0 dispatch-mask char-mode implementation number-threads chunk-size)
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
                               (wc-fd fd dispatch-mask char-mode implementation number-threads chunk-size)
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
