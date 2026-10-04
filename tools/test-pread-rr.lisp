(require :asdf)
(require :sb-posix)

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename "/home/arthur/repos/cl/wordcount") asdf:*central-registry*)
(asdf:load-system "wordcount")

(in-package :wc)

(sb-alien:define-alien-routine ("pread" pread) sb-alien:long
  (fd sb-alien:int)
  (buf sb-sys:system-area-pointer)
  (count sb-alien:unsigned-long)
  (offset sb-alien:long))

(defun wc-pread-mt (path &key (nthreads 8) (buf-size (* 256 1024)))
  (let* ((fd (sb-posix:open path sb-posix:o-rdonly))
         (size (sb-posix:stat-size (sb-posix:fstat fd)))
         (blocks (ceiling size buf-size))
         (results (make-array nthreads :initial-element nil)))
    ;; posix_fadvise
    (sb-posix:posix-fadvise fd 0 size 2) ;; POSIX_FADV_SEQUENTIAL
    (time
     (let ((threads
             (loop for tid from 0 below nthreads
                   collect
                   (let ((my-tid tid))
                     (sb-thread:make-thread
                      (lambda ()
                        ;; Allocate buffer with 64 extra bytes for lookback/alignment
                        (let* ((raw-buf (sb-alien:make-alien sb-alien:unsigned-char (+ buf-size 64)))
                               (raw-sap (sb-alien:alien-sap raw-buf))
                               (buf-sap (sb-sys:sap+ raw-sap 64))
                               (t-lines 0)
                               (t-words 0)
                               (t-chars 0))
                          (declare (type fixnum t-lines t-words t-chars))
                          (unwind-protect
                               (loop for block of-type fixnum from my-tid below blocks by nthreads
                                     do (let* ((offset (* block buf-size))
                                               (bytes-to-read (min buf-size (- size offset)))
                                               ;; Read 1 byte before offset if block > 0
                                               (read-offset (if (zerop block) offset (1- offset)))
                                               (read-len (if (zerop block) bytes-to-read (1+ bytes-to-read)))
                                               (dest-sap (if (zerop block) buf-sap (sb-sys:sap+ buf-sap -1))))
                                          (let ((n (pread fd dest-sap read-len read-offset)))
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
                            (sb-alien:free-alien raw-buf))
                          (setf (aref results my-tid) (list t-lines t-words t-chars)))))))))
       (dolist (th threads)
         (sb-thread:join-thread th))
       (let ((total-lines 0) (total-words 0) (total-chars 0))
         (loop for r across results do
           (incf total-lines (first r))
           (incf total-words (second r))
           (incf total-chars (third r)))
         (format t "Result: ~A lines, ~A words, ~A chars~%" total-lines total-words total-chars))))
    (sb-posix:close fd)))

(format t "Running wc-pread-mt on plato1g.txt:~%")
(dolist (nth (list 1 2 4 8 10 12))
  (format t "~%=== ~A THREADS ===~%" nth)
  (wc-pread-mt "/home/arthur/repos/cl/wordcount/tests/plato1g.txt" :nthreads nth))
