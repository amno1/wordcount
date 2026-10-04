(require :asdf)
(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename "/home/arthur/repos/cl/wordcount") asdf:*central-registry*)
(asdf:load-system "wordcount")
(in-package :wc)

(defun bench-mt-read-sequence (path &key (nthreads 8) (buf-size (* 1024 1024)))
  (let* ((fd (sb-posix:open path sb-posix:o-rdonly))
         (size (sb-posix:stat-size (sb-posix:fstat fd)))
         (blocks (ceiling size buf-size))
         (results (make-array nthreads :initial-element nil)))
    (sb-posix:close fd)
    (time
     (let ((threads
             (loop for tid from 0 below nthreads
                   collect
                   (let ((my-tid tid))
                     (sb-thread:make-thread
                      (lambda ()
                        (with-open-file (s path :direction :input :element-type '(unsigned-byte 8))
                          (let* ((arr (make-array buf-size :element-type '(unsigned-byte 8)))
                                 (t-lines 0) (t-words 0) (t-chars 0))
                            (sb-sys:with-pinned-objects (arr)
                              (let ((sap (sb-sys:vector-sap arr)))
                                (loop for block of-type fixnum from my-tid below blocks by nthreads
                                      do (let* ((offset (* block buf-size))
                                                (bytes-to-read (min buf-size (- size offset))))
                                           (file-position s offset)
                                           (let ((n (read-sequence arr s :end bytes-to-read)))
                                             (when (> n 0)
                                               (let ((init-ws #xFF))
                                                 (multiple-value-bind (l w c)
                                                     (count-lines-words-and-chars-ascii-avx512 sap n init-ws)
                                                   (incf t-lines l) (incf t-words w) (incf t-chars c)))))))))
                            (setf (aref results my-tid) (list t-lines t-words t-chars))))))))))
       (dolist (th threads) (sb-thread:join-thread th))
       (let ((total-lines 0) (total-words 0) (total-chars 0))
         (loop for r across results do
           (incf total-lines (first r))
           (incf total-words (second r))
           (incf total-chars (third r)))
         (format t "Result: ~A lines, ~A words, ~A chars~%" total-lines total-words total-chars))
       results))))

(format t "Testing multithreaded open + file-position + read-sequence (8 threads):~%")
(bench-mt-read-sequence "/home/arthur/repos/cl/wordcount/tests/plato1g.txt")
