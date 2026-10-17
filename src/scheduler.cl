;;; scheduler.cl
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

;;; Multi-threaded and single-threaded scheduling over file descriptors.
;;; Provides `process-fd`, `process-fd-linear`, `process-fd-mt`, and pool management.

;;; Code:

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 1)))

(defstruct (work-item (:copier nil))
  (fd 0 :type fixnum)
  (size 0 :type fixnum)
  (blocks 0 :type fixnum)
  (actual-buf-size 0 :type fixnum)
  (nthreads 0 :type fixnum)
  (dispatch-mask 0 :type (unsigned-byte 3))
  (char-mode nil :type (member nil :bytes :chars :chars-strict))
  (implementation :avx2 :type (member :generic :avx2 :avx512)))

(defstruct (worker (:constructor make-worker))
  (tid 0 :type fixnum)
  (thread nil)
  (start-sem (sb-thread:make-semaphore) :type sb-thread:semaphore)
  (raw (sb-sys:int-sap 0) :type sb-sys:system-area-pointer)
  (buf-sap (sb-sys:int-sap 0) :type sb-sys:system-area-pointer)
  (allocated-size 0 :type fixnum)
  (current-work nil)
  (error nil)
  (t-lines 0 :type fixnum)
  (t-words 0 :type fixnum)
  (t-chars 0 :type fixnum))

(defstruct (worker-pool (:conc-name pool-))
  (nthreads 0 :type fixnum)
  (chunk-size 0 :type fixnum)
  (workers #() :type simple-vector)
  (done-sem (sb-thread:make-semaphore) :type sb-thread:semaphore)
  (running t :type boolean))

(sb-ext:defglobal *worker-pool* nil)
(sb-ext:defglobal *pool-lock* (sb-thread:make-mutex :name "wc-pool-lock"))

(defun worker-do-blocks (w work)
  (declare (type worker w) (type work-item work)
           (optimize (speed 3) (safety 0)))
  (let ((my-tid (worker-tid w))
        (fd (work-item-fd work))
        (size (work-item-size work))
        (blocks (work-item-blocks work))
        (actual-buf-size (work-item-actual-buf-size work))
        (nthreads (work-item-nthreads work))
        (dispatch-mask (work-item-dispatch-mask work))
        (char-mode (work-item-char-mode work))
        (implementation (work-item-implementation work))
        (buf-sap (worker-buf-sap w))
        (t-lines 0) (t-words 0) (t-chars 0))
    (declare (type fixnum my-tid fd size blocks actual-buf-size nthreads t-lines t-words t-chars)
             (type (unsigned-byte 3) dispatch-mask)
             (type (member nil :bytes :chars :chars-strict) char-mode)
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
                                         (if (or (= b 32) (<= 9 b 13)) #xFF #x00))))
                          (init-ed (if (zerop block)
                                       0
                                       (let ((b (sb-sys:sap-ref-8 buf-sap -1)))
                                         (if (= b #xED) 1 0)))))
                     (declare (type fixnum actual-len) (type (unsigned-byte 8) init-ws init-ed))
                     (multiple-value-bind (l w c)
                         (dispatch-kernel implementation dispatch-mask char-mode buf-sap actual-len init-ws init-ed)
                       (incf t-lines l)
                       (incf t-words w)
                       (incf t-chars c)))))))
    (setf (worker-t-lines w) t-lines
          (worker-t-words w) t-words
          (worker-t-chars w) t-chars)))

(defun worker-loop (w p)
  (loop
    (sb-thread:wait-on-semaphore (worker-start-sem w))
    (unless (pool-running p)
      (return))
    (let ((work (worker-current-work w)))
      (unwind-protect
           (when work
             (handler-case
                 (worker-do-blocks w work)
               (error (e)
                 (setf (worker-error w) e))))
        (sb-thread:signal-semaphore (pool-done-sem p))))))

(defun shutdown-worker-pool ()
  "Shut down all worker threads and free allocated foreign memory."
  (sb-thread:with-mutex (*pool-lock*)
    (when *worker-pool*
      (let* ((p *worker-pool*)
             (workers (pool-workers p))
             (n (pool-nthreads p)))
        (setf (pool-running p) nil)
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
        (setf *worker-pool* nil)))))

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
                                            :done-sem done-sem
                                            :running t))
                   (aligned-alloc-size (round-up-64 (+ chunk-size 64))))
              (dotimes (i nthreads)
                (let* ((raw (sb-posix:aligned-alloc 64 aligned-alloc-size))
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

(defun process-fd-linear (fd dispatch-mask char-mode implementation &optional (buf-size +default-chunk-size+))
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

(defun process-fd-mt (fd size nthreads dispatch-mask char-mode implementation
                      &optional (buf-size +default-chunk-size+))
  (declare (type fixnum fd size nthreads buf-size)
           (type (unsigned-byte 3) dispatch-mask)
           (type (member nil :bytes :chars :chars-strict) char-mode)
           (type (member :generic :avx2 :avx512) implementation))
  (sb-posix:posix-fadvise fd 0 size 2) ;; POSIX_FADV_SEQUENTIAL
  (let* ((actual-buf-size (max 64 buf-size))
         (blocks (the fixnum (ceiling size actual-buf-size)))
         (pool (ensure-worker-pool nthreads actual-buf-size))
         (work (make-work-item :fd fd :size size :blocks blocks
                               :actual-buf-size actual-buf-size
                               :nthreads nthreads
                               :dispatch-mask dispatch-mask
                               :char-mode char-mode
                               :implementation implementation))
         (completed nil))
    (dotimes (i nthreads)
      (let ((w (aref (pool-workers pool) i)))
        (setf (worker-current-work w) work
              (worker-error w) nil
              (worker-t-lines w) 0
              (worker-t-words w) 0
              (worker-t-chars w) 0)))
    (unwind-protect
         (progn
           ;; Wake up remote workers (1 .. nthreads-1)
           (loop for i of-type fixnum from 1 below nthreads
                 for w = (aref (pool-workers pool) i)
                 do (sb-thread:signal-semaphore (worker-start-sem w)))
           ;; Main thread runs worker 0
           (handler-case
               (worker-do-blocks (aref (pool-workers pool) 0) work)
             (error (e)
               (setf (worker-error (aref (pool-workers pool) 0)) e)))
           ;; Wait for remote workers
           (dotimes (i (1- nthreads))
             (sb-thread:wait-on-semaphore (pool-done-sem pool)))
           (setf completed t))
      (if completed
          (dotimes (i nthreads)
            (setf (worker-current-work (aref (pool-workers pool) i)) nil))
          ;; Aborted before all workers finished: shut down pool to join threads
          ;; and reset state so no stale semaphore counts or orphaned threads remain.
          (shutdown-worker-pool)))

    ;; Check for worker errors
    (let ((worker-err nil))
      (dotimes (i nthreads)
        (let ((w (aref (pool-workers pool) i)))
          (when (worker-error w)
            (setf worker-err (worker-error w)))))
      (if worker-err
          (values 0 0 0 size worker-err)
          (let ((total-lines 0)
                (total-words 0)
                (total-chars 0))
            (declare (type fixnum total-lines total-words total-chars))
            (loop for i of-type fixnum from 0 below nthreads
                  for w = (aref (pool-workers pool) i)
                  do (incf total-lines (worker-t-lines w))
                     (incf total-words (worker-t-words w))
                     (incf total-chars (worker-t-chars w)))
            (values total-lines total-words total-chars size nil))))))

(defun process-fd (fd dispatch-mask char-mode implementation nthreads &optional (buf-size +default-chunk-size+))
  "Process FD using single-threaded linear stream reads or multi-threaded pread blocks.
Returns (VALUES LINES WORDS CHARS BYTES ERROR)."
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
                   (process-fd-linear fd dispatch-mask char-mode implementation buf-size)
                   (process-fd-mt fd size nthreads dispatch-mask char-mode implementation buf-size))))))
      ;; Empty file
      ((and cur end (= cur end))
       (values 0 0 0 0 nil))
      ;; Non-seekable stream (stdin, pipes, sockets)
      (t
       (process-fd-linear fd dispatch-mask char-mode implementation buf-size)))))

;;; scheduler.cl ends here
