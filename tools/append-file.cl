;; append-file.cl
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

(in-package "CL-USER")

(uiop:define-package "APPEND-FILE"
    (:use #:cl)
  (:export #:append-file))

(in-package "APPEND-FILE")

(defun append-file (from to &key (repeat-count 1) (buffer-size #.(expt 2 20)))
  (with-open-file (outstream to
                             :direction :output
                             :if-exists :append
                             :if-does-not-exist :create
                             :element-type '(unsigned-byte 8))
    (loop repeat repeat-count do
      (with-open-file (instream from
                                :direction :input
                                :element-type '(unsigned-byte 8))
        (let* ((file-length (file-length instream))
               (read-size (min buffer-size file-length))
               (buffer (make-array read-size
                                   :element-type '(unsigned-byte 8))))
          (loop while (> file-length 0) do
            (let ((position (read-sequence buffer instream :end read-size)))
              (write-sequence buffer outstream :end position)
              (decf file-length position))))))))

;;; append-file.cl ends here
