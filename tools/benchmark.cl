;; benchmark.cl
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

;;; Code:

(in-package #:wc-benchmark)

(eval-when (:compile-toplevel)
  (org.shirakumo.trivial-benchmark:add-nickname))

(defun wc-simple (wc file-path &key (iterations 100))
  "Run the word counter multiple times using the functional interface."
  (declare (optimize (speed 1) (safety 1) (debug 2)))
  (format t "=== Benchmarking wc on '~A' over ~D iterations ===~%" file-path iterations)
  (let ((timer (make-instance 'tb:timer)))
    (loop repeat iterations do
      (tb:with-sampling (timer)
        (funcall wc file-path)))
    (tb:report timer)))

(defun wc-suite (wc file-list &rest args &key (iterations 100) &allow-other-keys)
  "Evaluates each hyper-specialized pipeline combination immediately using a tb:timer loop."
  (declare (type list file-list)
           (type fixnum iterations)
           (optimize (speed 1) (safety 1) (debug 2)))
  
  (format t "~% Lines Only ~%")
  (let ((timer (make-instance 'tb:timer)))
    (loop repeat iterations do
      (tb:with-sampling (timer)
        (apply wc file-list :count-lines t :allow-other-keys t args)))
    (tb:report timer))

  (format t "~% Characters Only ~%")
  (let ((timer (make-instance 'tb:timer)))
    (loop repeat iterations do
      (tb:with-sampling (timer)
        (apply wc file-list :count-characters t :allow-other-keys t args)))
    (tb:report timer))
  
  (format t "~% Lines & Words ~%")
  (let ((timer (make-instance 'tb:timer)))
    (loop repeat iterations do
      (tb:with-sampling (timer)
        (apply wc file-list :count-lines t :count-words t :allow-other-keys t args)))
    (tb:report timer))

  (format t "~% Lines, Words, & Characters ~%")
  (let ((timer (make-instance 'tb:timer)))
    (loop repeat iterations do
      (tb:with-sampling (timer)
        (apply wc file-list :allow-other-keys t args)))
    (tb:report timer))
  
  (values))

;;; benchmark.cl ends here
