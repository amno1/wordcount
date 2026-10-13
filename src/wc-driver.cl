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
           (let ((n (the fixnum (sb-posix:posix-read fd buf-sap actual-buf-size))))
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

(defstruct (worker (:constructor make-worker))
  (tid 0 :type fixnum)
  (thread nil)
  (start-sem (sb-thread:make-semaphore) :type sb-thread:semaphore)
  (raw (sb-sys:int-sap 0) :type sb-sys:system-area-pointer)
  (buf-sap (sb-sys:int-sap 0) :type sb-sys:system-area-pointer)
  (allocated-size 0 :type fixnum)
  (t-lines 0 :type fixnum)
  (t-words 0 :type fixnum)
  (t-chars 0 :type fixnum))

(defstruct (worker-pool (:conc-name pool-))
  (nthreads 0 :type fixnum)
  (chunk-size 0 :type fixnum)
  (workers #() :type simple-vector)
  (done-sem (sb-thread:make-semaphore) :type sb-thread:semaphore))

(sb-ext:defglobal *worker-pool* nil)
(sb-ext:defglobal *pool-lock* (sb-thread:make-mutex :name "wc-pool-lock"))

(sb-ext:defglobal *pool-fd* 0)
(sb-ext:defglobal *pool-size* 0)
(sb-ext:defglobal *pool-blocks* 0)
(sb-ext:defglobal *pool-actual-buf-size* 0)
(sb-ext:defglobal *pool-nthreads* 0)
(sb-ext:defglobal *pool-dispatch-mask* 0)
(sb-ext:defglobal *pool-utf8* nil)
(sb-ext:defglobal *pool-implementation* :avx512)
(sb-ext:defglobal *pool-running* t)

(defun worker-do-blocks (w)
  (declare (type worker w) (optimize (speed 3) (safety 0)))
  (let ((my-tid (worker-tid w))
        (fd *pool-fd*)
        (size *pool-size*)
        (blocks *pool-blocks*)
        (actual-buf-size *pool-actual-buf-size*)
        (nthreads *pool-nthreads*)
        (dispatch-mask *pool-dispatch-mask*)
        (utf8 *pool-utf8*)
        (implementation *pool-implementation*)
        (buf-sap (worker-buf-sap w))
        (t-lines 0) (t-words 0) (t-chars 0))
    (declare (type fixnum my-tid fd size blocks actual-buf-size nthreads t-lines t-words t-chars)
             (type (unsigned-byte 3) dispatch-mask)
             (type sb-sys:system-area-pointer buf-sap))
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
                     (declare (type fixnum actual-len) (type (unsigned-byte 8) init-ws))
                     (multiple-value-bind (l w c)
                         (dispatch-kernel implementation dispatch-mask utf8 buf-sap actual-len init-ws)
                       (incf t-lines l)
                       (incf t-words w)
                       (incf t-chars c)))))))
    (setf (worker-t-lines w) t-lines
          (worker-t-words w) t-words
          (worker-t-chars w) t-chars)))

(defun worker-loop (w p)
  (loop
    (sb-thread:wait-on-semaphore (worker-start-sem w))
    (unless *pool-running*
      (return))
    (unwind-protect
         (worker-do-blocks w)
      (sb-thread:signal-semaphore (pool-done-sem p)))))

(defun shutdown-worker-pool ()
  (sb-thread:with-mutex (*pool-lock*)
    (when *worker-pool*
      (let* ((p *worker-pool*)
             (workers (pool-workers p))
             (n (pool-nthreads p)))
        (setf *pool-running* nil)
        (loop for i from 1 below n
              for w = (aref workers i)
              do (sb-thread:signal-semaphore (worker-start-sem w)))
        (loop for i from 1 below n
              for w = (aref workers i)
              when (worker-thread w)
              do (sb-thread:join-thread (worker-thread w)))
        (loop for i from 0 below n
              for w = (aref workers i)
              when (not (sb-sys:sap= (worker-raw w) (sb-sys:int-sap 0)))
              do (sb-posix:alien-free (worker-raw w))
                 (setf (worker-raw w) (sb-sys:int-sap 0)
                       (worker-buf-sap w) (sb-sys:int-sap 0)))
        (setf *worker-pool* nil
              *pool-running* t)))))

(defun ensure-worker-pool (nthreads chunk-size)
  (declare (type fixnum nthreads chunk-size))
  (sb-thread:with-mutex (*pool-lock*)
    (let ((p *worker-pool*))
      (if (and p
               (>= (pool-nthreads p) nthreads)
               (>= (pool-chunk-size p) chunk-size))
          p
          (progn
            (when p (shutdown-worker-pool))
            (let* ((done-sem (sb-thread:make-semaphore))
                   (workers (make-array nthreads))
                   (new-p (make-worker-pool :nthreads nthreads
                                            :chunk-size chunk-size
                                            :workers workers
                                            :done-sem done-sem)))
              (setf *pool-running* t)
              (dotimes (i nthreads)
                (let* ((raw (sb-posix:aligned-alloc 64 (+ chunk-size 64)))
                       (buf-sap (sb-sys:sap+ raw 64))
                       (w (make-worker :tid i :raw raw :buf-sap buf-sap :allocated-size chunk-size)))
                  (setf (aref workers i) w)
                  (when (> i 0)
                    (setf (worker-thread w)
                          (sb-thread:make-thread
                           (lambda () (worker-loop w new-p))
                           :name (format nil "wc-worker-~d" i))))))
              (setf *worker-pool* new-p)
              new-p))))))

(defun wc-fd-mt (fd size nthreads dispatch-mask utf8 implementation
                 &optional (buf-size +default-chunk-size+))
  (declare (type fixnum fd size nthreads buf-size)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member :generic :avx2 :avx512) implementation))
  (sb-posix:posix-fadvise fd 0 size 2) ;; POSIX_FADV_SEQUENTIAL
  (let* ((actual-buf-size (max 64 buf-size))
         (blocks (the fixnum (ceiling size actual-buf-size)))
         (pool (ensure-worker-pool nthreads actual-buf-size)))
    (setf *pool-fd* fd
          *pool-size* size
          *pool-blocks* blocks
          *pool-actual-buf-size* actual-buf-size
          *pool-nthreads* nthreads
          *pool-dispatch-mask* dispatch-mask
          *pool-utf8* utf8
          *pool-implementation* implementation)
    ;; Wake up remote workers (1 .. nthreads-1)
    (loop for i of-type fixnum from 1 below nthreads
          for w = (aref (pool-workers pool) i)
          do (sb-thread:signal-semaphore (worker-start-sem w)))
    ;; Main thread runs worker 0
    (worker-do-blocks (aref (pool-workers pool) 0))
    ;; Wait for remote workers
    (dotimes (i (1- nthreads))
      (sb-thread:wait-on-semaphore (pool-done-sem pool)))
    ;; Sum results
    (let ((total-lines 0)
          (total-words 0)
          (total-chars 0))
      (declare (type fixnum total-lines total-words total-chars))
      (loop for i of-type fixnum from 0 below nthreads
            for w = (aref (pool-workers pool) i)
            do (incf total-lines (worker-t-lines w))
               (incf total-words (worker-t-words w))
               (incf total-chars (worker-t-chars w)))
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
            (declare (type simple-string path))
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
