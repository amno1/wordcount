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
;; Uses thread-local aligned buffers, user-configurable chunk/buffer size,
;; round-robin pread for large files (>= 8 MB), and linear read for
;; small files and non-seekable streams (pipes/stdin).

;;; Code:

#-sbcl
(error "This file requires SBCL compiler.")

(declaim (optimize (speed 3) (safety 0)))

(in-package :wc)

(declaim (inline count-lines-words-and-chars-utf8
                 count-lines-words-and-chars-ascii
                 count-lines-utf8 count-words-utf8 count-chars-utf8
                 count-lines-ascii count-words-ascii count-chars-ascii
                 count-lines-and-words-utf8 count-words-and-chars-utf8 count-lines-and-chars-utf8
                 count-lines-and-words-ascii count-words-and-chars-ascii count-lines-and-chars-ascii))

(defmacro kernel-call (base-name implementation &rest args)
  (let* ((name-string (symbol-name base-name))
         (generic-fn (intern (concatenate 'string name-string "-GENERIC") :wc))
         (avx512-fn  (intern (concatenate 'string name-string "-AVX512")  :wc)))
    `(ecase ,implementation
       (:generic (,generic-fn ,@args))
       (:avx2    (,base-name ,@args))
       (:avx512  ,(if (find :avx512 *features*)
                      `(,avx512-fn ,@args)
                      `(,base-name ,@args))))))

(declaim (inline dispatch-kernel))
(defun dispatch-kernel (implementation dispatch-mask utf8 sap size init-ws)
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum size)
           (type (unsigned-byte 8) init-ws)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member :generic :avx2 :avx512) implementation))
  (multiple-value-bind (lc wc cc)
      (case dispatch-mask
        ((or 0 7)
         (if utf8
             (if (eq utf8 'strict)
                 (kernel-call count-lines-words-and-chars-utf8-strict implementation sap size init-ws)
                 (kernel-call count-lines-words-and-chars-utf8 implementation sap size init-ws))
             (kernel-call count-lines-words-and-chars-ascii implementation sap size init-ws)))
        (1
         (if utf8
             (if (eq utf8 'strict)
                 (kernel-call count-chars-utf8-strict implementation sap size)
                 (kernel-call count-chars-utf8 implementation sap size))
             (kernel-call count-chars-ascii implementation sap size)))

        (2
         (kernel-call count-words-ascii implementation sap size init-ws))

        (3
         (if utf8
             (if (eq utf8 'strict)
                 (kernel-call count-words-and-chars-utf8-strict implementation sap size init-ws)
                 (kernel-call count-words-and-chars-utf8 implementation sap size init-ws))
             (kernel-call count-words-and-chars-ascii implementation sap size init-ws)))
        (4 (kernel-call count-lines-ascii implementation sap size))

        (5
         (if utf8
             (if (eq utf8 'strict)
                 (kernel-call count-lines-and-chars-utf8-strict implementation sap size)
                 (kernel-call count-lines-and-chars-utf8 implementation sap size))
             (kernel-call count-lines-and-chars-ascii implementation sap size)))
        (6
         (kernel-call count-lines-and-words-ascii implementation sap size init-ws)))

    (values (the fixnum (or lc 0))
            (the fixnum (or wc 0))
            (the fixnum (or cc 0)))))

(defun wc-fd-linear (fd dispatch-mask utf8 implementation &optional (buf-size +default-chunk-size+))
  (declare (type fixnum fd buf-size)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member :generic :avx2 :avx512) implementation))
  (let* ((actual-buf-size (max 64 buf-size))
         (raw (sb-posix:aligned-alloc 64 (+ actual-buf-size 64)))
         (buf-sap (sb-sys:sap+ raw 64))
         (prev-ws #xFF)
         (t-lines 0)
         (t-words 0)
         (t-chars 0))
    (declare (type fixnum t-lines t-words t-chars actual-buf-size)
             (type (unsigned-byte 8) prev-ws)
             (type sb-sys:system-area-pointer raw buf-sap))
    (unwind-protect
         (loop
           (let ((n (the fixnum (sb-posix:read fd buf-sap actual-buf-size))))
             (when (<= n 0) (return))
             (multiple-value-bind (l w c)
                 (dispatch-kernel implementation dispatch-mask utf8 buf-sap n prev-ws)
               (incf t-lines l)
               (incf t-words w)
               (incf t-chars c)
               (let ((last-b (sb-sys:sap-ref-8 buf-sap (1- n))))
                 (setf prev-ws (if (or (= last-b 32) (<= 9 last-b 13)) #xFF #x00))))))
      (sb-posix:alien-free raw))
    (values t-lines t-words t-chars)))

(defun wc-fd-mt (fd size nthreads dispatch-mask utf8 implementation
                 &optional (buf-size +default-chunk-size+))
  (declare (type fixnum fd size nthreads buf-size)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member :generic :avx2 :avx512) implementation))
  (sb-posix:posix-fadvise fd 0 size 2) ;; POSIX_FADV_SEQUENTIAL
  (let* ((actual-buf-size (max 64 buf-size))
         (blocks (the fixnum (ceiling size actual-buf-size)))
         (results (make-array nthreads :initial-element nil))
         (threads
           (loop for tid of-type fixnum from 0 below nthreads
                 collect
                 (let ((my-tid tid))
                   (sb-thread:make-thread
                    (lambda ()
                      (let* ((raw (sb-posix:aligned-alloc 64 (+ actual-buf-size 64)))
                             (buf-sap (sb-sys:sap+ raw 64))
                             (t-lines 0)
                             (t-words 0)
                             (t-chars 0))
                        (declare (type fixnum t-lines t-words t-chars)
                                 (type sb-sys:system-area-pointer raw buf-sap))
                        (unwind-protect
                             (loop for block of-type fixnum from my-tid below blocks by nthreads
                                   do (let* ((offset (* block actual-buf-size))
                                             (bytes-to-read (min actual-buf-size (- size offset)))
                                             (read-offset (if (zerop block) offset (1- offset)))
                                             (read-len (if (zerop block) bytes-to-read (1+ bytes-to-read)))
                                             (dest-sap (if (zerop block) buf-sap (sb-sys:sap+ buf-sap -1))))
                                        (declare (type fixnum offset bytes-to-read read-offset read-len)
                                                 (type sb-sys:system-area-pointer dest-sap))
                                        (let ((n (the fixnum (sb-posix:pread fd dest-sap read-len read-offset))))
                                          (when (> n 0)
                                            (let* ((actual-len (if (zerop block) n (1- n)))
                                                   (init-ws (if (zerop block)
                                                                #xFF
                                                                (let ((b (sb-sys:sap-ref-8 buf-sap -1)))
                                                                  (if (or (= b 32) (<= 9 b 13)) #xFF #x00)))))
                                              (declare (type fixnum actual-len)
                                                       (type (unsigned-byte 8) init-ws))
                                              (multiple-value-bind (l w c)
                                                  (dispatch-kernel implementation dispatch-mask utf8 buf-sap actual-len init-ws)
                                                (incf t-lines l)
                                                (incf t-words w)
                                                (incf t-chars c)))))))
                          (sb-posix:alien-free raw))
                        (setf (aref results my-tid) (list t-lines t-words t-chars))))
                    :name (format nil "wc-worker-~d" my-tid))))))
    (dolist (th threads)
      (sb-thread:join-thread th))
    (let ((total-lines 0)
          (total-words 0)
          (total-chars 0))
      (declare (type fixnum total-lines total-words total-chars))
      (loop for r across results
            when r
            do (incf total-lines (the fixnum (first r)))
               (incf total-words (the fixnum (second r)))
               (incf total-chars (the fixnum (third r))))
      (values total-lines total-words total-chars))))

(defun wc-fd (fd dispatch-mask utf8 implementation nthreads &optional (buf-size +default-chunk-size+))
  (declare (type fixnum fd nthreads buf-size)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member :generic :avx2 :avx512) implementation))
  (let* ((cur (ignore-errors (sb-posix:lseek fd 0 sb-posix:seek-cur)))
         (end (ignore-errors (sb-posix:lseek fd 0 sb-posix:seek-end))))
    (cond
      ;; Seekable regular file
      ((and cur end (>= cur 0) (>= end 0) (> end cur))
       (let ((size (- end cur)))
         (declare (type fixnum size))
         ;; Rewind to start of file / cur
         (sb-posix:lseek fd cur sb-posix:seek-set)
         (if (or (<= nthreads 1) (< size (* 8 1024 1024)))
             ;; Sequential read avoids thread spawning overhead for small files
             (wc-fd-linear fd dispatch-mask utf8 implementation buf-size)
             ;; Multi-threaded pread for large files
             (wc-fd-mt fd size nthreads dispatch-mask utf8 implementation buf-size))))
      ;; Empty file
      ((and cur end (= cur end))
       (values 0 0 0))
      ;; Non-seekable stream (stdin, pipes, sockets)
      (t
       (wc-fd-linear fd dispatch-mask utf8 implementation buf-size)))))

(defun wc (file-list &key count-lines count-words count-characters utf8
                       (implementation :avx2)
                       (number-threads (min 8 (ncpus)))
                       (chunk-size +default-chunk-size+))
  (let ((dispatch-mask (make-dispatch-mask count-lines
                                          count-words
                                          count-characters))
        (final-results nil))
    (declare (type (unsigned-byte 3) dispatch-mask)
             (type (member :generic :avx2 :avx512) implementation)
             (type fixnum number-threads chunk-size))

    (flet ((format-result (lines words chars path)
             (let (file-results)
               (when (or count-lines (zerop dispatch-mask))
                 (push lines file-results))
               (when (or count-words (zerop dispatch-mask))
                 (push words file-results))
               (when (or count-characters (zerop dispatch-mask))
                 (push chars file-results))
               (nconc (nreverse file-results) (if path (list path) nil)))))

      (if (null file-list)
          ;; Read from STDIN
          (multiple-value-bind (l w c)
              (wc-fd 0 dispatch-mask utf8 implementation number-threads chunk-size)
            (setf final-results (list (format-result l w c ""))))
          ;; Process each file in file-list
          (dolist (path file-list)
            (declare (type string path))
            (if (string= path "-")
                (multiple-value-bind (l w c)
                    (wc-fd 0 dispatch-mask utf8 implementation number-threads chunk-size)
                  (push (format-result l w c "-") final-results))
                (let ((fd (sb-posix:open path sb-posix:o-rdonly)))
                  (unwind-protect
                       (multiple-value-bind (l w c)
                           (wc-fd fd dispatch-mask utf8 implementation number-threads chunk-size)
                         (push (format-result l w c path) final-results))
                    (sb-posix:close fd))))))
      (if (null file-list)
          final-results
          (nreverse final-results)))))

;;; wc-driver.cl ends here
