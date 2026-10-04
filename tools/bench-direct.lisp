;; bench-direct.lisp
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

;;

(require :asdf)

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(push (truename "/home/arthur/repos/cl/wordcount") asdf:*central-registry*)
(asdf:load-system "wordcount")

(in-package :wc)

(defun test-direct (path nthreads)
  (let* ((fd (sb-posix:open path sb-posix:o-rdonly))
         (size (sb-posix:stat-size (sb-posix:fstat fd)))
         (sap (sb-posix:mmap nil size sb-posix:prot-read sb-posix:map-private fd 0))
         (chunk-size (ceiling size nthreads))
         (results (make-array nthreads :initial-element nil)))
    (sb-posix:posix-madvise sap size 3)
    (time
     (let ((threads
             (loop for tid from 0 below nthreads
                   collect
                   (let* ((start (* tid chunk-size))
                          (end (min size (* (1+ tid) chunk-size)))
                          (aligned-start (if (zerop start) 0 (logandc2 start 127)))
                          (aligned-end (if (= end size) size (logandc2 end 127)))
                          (s (- aligned-end aligned-start))
                          (sub-sap (sb-sys:sap+ sap aligned-start))
                          (bofp (zerop aligned-start))
                          (init-ws (if (or bofp
                                           (let ((b (sb-sys:sap-ref-8 sap (1- aligned-start))))
                                             (or (= b 32) (<= 9 b 13))))
                                       #xFF
                                       #x00))
                          (idx tid))
                     (sb-thread:make-thread
                      (lambda ()
                        (multiple-value-bind (lc wc cc)
                            (count-lines-words-and-chars-ascii-avx512 sub-sap s init-ws)
                          (setf (aref results idx) (list lc wc cc)))))))))
       (dolist (th threads)
         (sb-thread:join-thread th))
       (let ((total-lines 0) (total-words 0) (total-chars 0))
         (loop for r across results do
           (incf total-lines (first r))
           (incf total-words (second r))
           (incf total-chars (third r)))
         (format t "Result: ~A lines, ~A words, ~A chars~%" total-lines total-words total-chars))))
    (sb-posix:munmap sap size)
    (sb-posix:close fd)))

(format t "Testing with direct sb-thread on plato1g.txt:~%")
(dolist (nth (list 1 2 4 8 10 12 16 20))
  (format t "~% ~A THREADS~%" nth)
  (test-direct "/home/arthur/repos/cl/wordcount/tests/plato1g.txt" nth))

;;; bench-direct.cl ends here
