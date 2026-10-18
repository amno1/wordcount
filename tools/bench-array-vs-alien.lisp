(require :asdf)
(require :sb-posix)

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(let ((root (truename (merge-pathnames "../" (or *load-truename* *default-pathname-defaults*)))))
  (pushnew root asdf:*central-registry* :test #'equal))
(asdf:load-system "wordcount")

(in-package :wc)

;;; 1. Alien buffer (aligned_alloc 64-byte aligned)
(defun bench-alien-buffer (path &key (nthreads 8) (buf-size (* 1024 1024)))
  (let* ((fd (sb-posix:open path sb-posix:o-rdonly))
         (size (sb-posix:stat-size (sb-posix:fstat fd)))
         (blocks (ceiling size buf-size))
         (results (make-array nthreads :initial-element nil)))
    (sb-posix:posix-fadvise fd 0 size 2)
    (let ((threads
            (loop for tid from 0 below nthreads
                  collect
                  (let ((my-tid tid))
                    (sb-thread:make-thread
                     (lambda ()
                       (let* ((alloc-size (+ buf-size 64))
                              (raw-sap (sb-posix:aligned-alloc 64 alloc-size))
                              (buf-sap (sb-sys:sap+ raw-sap 64))
                              (t-lines 0) (t-words 0) (t-chars 0))
                         (declare (type fixnum t-lines t-words t-chars))
                         (unwind-protect
                              (loop for block of-type fixnum from my-tid below blocks by nthreads
                                    do (let* ((offset (* block buf-size))
                                              (bytes-to-read (min buf-size (- size offset)))
                                              (read-offset (if (zerop block) offset (1- offset)))
                                              (read-len (if (zerop block) bytes-to-read (1+ bytes-to-read)))
                                              (dest-sap (if (zerop block) buf-sap (sb-sys:sap+ buf-sap -1))))
                                         (let ((n (sb-posix:pread fd dest-sap read-len read-offset)))
                                           (when (> n 0)
                                             (let* ((actual-len (if (zerop block) n (1- n)))
                                                    (init-ws (if (zerop block)
                                                                 #xFF
                                                                 (let ((prev-b (sb-sys:sap-ref-8 buf-sap -1)))
                                                                   (if (or (= prev-b 32) (<= 9 prev-b 13))
                                                                       #xFF
                                                                       #x00)))))
                                               (multiple-value-bind (l w c)
                                                   (count-lines-words-and-chars-ascii-avx512 buf-sap actual-len init-ws)
                                                 (incf t-lines l)
                                                 (incf t-words w)
                                                 (incf t-chars c)))))))
                           (sb-posix:alien-free raw-sap))
                         (setf (aref results my-tid) (list t-lines t-words t-chars)))))))))
      (dolist (th threads) (sb-thread:join-thread th))
      (sb-posix:close fd)
      results)))

;;; 2. Ordinary Typed Lisp Array (allocated once per thread, pinned during pread/SIMD)
(defun bench-lisp-array (path &key (nthreads 8) (buf-size (* 1024 1024)))
  (let* ((fd (sb-posix:open path sb-posix:o-rdonly))
         (size (sb-posix:stat-size (sb-posix:fstat fd)))
         (blocks (ceiling size buf-size))
         (results (make-array nthreads :initial-element nil)))
    (sb-posix:posix-fadvise fd 0 size 2)
    (let ((threads
            (loop for tid from 0 below nthreads
                  collect
                  (let ((my-tid tid))
                    (sb-thread:make-thread
                     (lambda ()
                       (let* ((arr (make-array (+ buf-size 128) :element-type '(unsigned-byte 8)))
                              (t-lines 0) (t-words 0) (t-chars 0))
                         (declare (type fixnum t-lines t-words t-chars)
                                  (type (simple-array (unsigned-byte 8) (*)) arr))
                         (sb-sys:with-pinned-objects (arr)
                           (let* ((raw-sap (sb-sys:vector-sap arr))
                                  (raw-addr (sb-sys:sap-int raw-sap))
                                  (aligned-addr (logandc2 (+ raw-addr 63 64) 63))
                                  (buf-sap (sb-sys:int-sap aligned-addr)))
                             (loop for block of-type fixnum from my-tid below blocks by nthreads
                                   do (let* ((offset (* block buf-size))
                                             (bytes-to-read (min buf-size (- size offset)))
                                             (read-offset (if (zerop block) offset (1- offset)))
                                             (read-len (if (zerop block) bytes-to-read (1+ bytes-to-read)))
                                             (dest-sap (if (zerop block) buf-sap (sb-sys:sap+ buf-sap -1))))
                                        (let ((n (sb-posix:pread fd dest-sap read-len read-offset)))
                                          (when (> n 0)
                                            (let* ((actual-len (if (zerop block) n (1- n)))
                                                   (init-ws (if (zerop block)
                                                                #xFF
                                                                (let ((prev-b (sb-sys:sap-ref-8 buf-sap -1)))
                                                                  (if (or (= prev-b 32) (<= 9 prev-b 13))
                                                                      #xFF
                                                                      #x00)))))
                                              (multiple-value-bind (l w c)
                                                  (count-lines-words-and-chars-ascii-avx512 buf-sap actual-len init-ws)
                                                (incf t-lines l)
                                                (incf t-words w)
                                                (incf t-chars c)))))))))
                         (setf (aref results my-tid) (list t-lines t-words t-chars)))))))))
      (dolist (th threads) (sb-thread:join-thread th))
      (sb-posix:close fd)
      results)))

(defun run-comparison (path &key (trials 5))
  (format t "~%================================================================~%")
  (format t "Comparing Alien Buffer vs Typed Lisp Array (pread + AVX-512)~%")
  (format t "Target file: ~A~%" path)
  (format t "Buffer size: 1 MiB, Threads: 8~%")
  (format t "================================================================~%~%")
  
  ;; Warmup
  (bench-alien-buffer path)
  (bench-lisp-array path)

  (format t "--- 1. Alien Buffer (posix aligned_alloc 64-byte aligned) ---~%")
  (dotimes (i trials)
    (format t "Trial ~D: " (1+ i))
    (time (bench-alien-buffer path)))

  (format t "~%--- 2. Typed Lisp Array (pinned simple-array (unsigned-byte 8)) ---~%")
  (dotimes (i trials)
    (format t "Trial ~D: " (1+ i))
    (time (bench-lisp-array path))))

(let* ((root (truename (merge-pathnames "../" (or *load-truename* *default-pathname-defaults*))))
       (p1g (merge-pathnames "tests/plato1g.txt" root))
       (file (if (probe-file p1g)
                 p1g
                 (merge-pathnames "tests/plato.org" root))))
  (when (probe-file file)
    (run-comparison (namestring file))))
