;; with-cli-parsing.cl
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

(in-package :wc)

(eval-when (:compile-toplevel :load-toplevel :execute)

  (defun ensure-list (thing)
    (if (listp thing)
        thing
        (list thing)))
  
  (defun cli-option-aliases (item)
    (cond
      ((stringp item) (list item))
      ((every #'stringp item) item)
      (t (ensure-list (car item)))))

  (defun cli-option-properties (item)
    (when (and (listp item)
               (not (every #'stringp item)))
      (cdr item)))

  (defun cli-option-target (aliases)
    (intern (string-upcase (first aliases)) :keyword))

  (defun cli-parse-option (item)
    (let* ((aliases    (cli-option-aliases item))
           (properties (cli-option-properties item))
           (target     (cli-option-target aliases)))
      (values aliases properties target)))

  (defun cli-parse-options (options)
    (let ((dispatch-clauses '())
          (required-trackers '()))
      (dolist (item options)
        (multiple-value-bind (aliases properties target)
            (cli-parse-option item)
          (dolist (alias aliases)
            (push `(,alias ',target) dispatch-clauses))
          (when (and properties (getf properties :required))
            (push (list target
                        (gensym (concatenate 'string
                                             (symbol-name target)
                                             "-SEEN"))
                        (first aliases))
                  required-trackers))))
      (values (nreverse dispatch-clauses)
              required-trackers)))

  (defun cli-required-bindings (required-trackers)
    (loop for track in required-trackers
          collect `(,(second track) nil)))

  (defun cli-required-markers (required-trackers)
    (loop for track in required-trackers
          collect `(,(first track) (setf ,(second track) t))))

  (defun cli-required-checks (required-trackers)
    (loop for track in required-trackers
          collect
          `(unless ,(second track)
             (print-help-and-quit
              "Missing required option: --~a" ,(third track)))))

  (defun cli-option-clauses (program-clauses)
    (remove-if (lambda (clause) (eq (car clause) :arg)) program-clauses))
  
  (defun cli-arg-clause (program-clauses)
    (assoc :arg program-clauses))

  (defun cli-main-loop-form (args-var pos-count dispatch-fn program-clauses)
    (let ((arg-clause (cli-arg-clause program-clauses)))
      `(loop while ,args-var do
         (let ((arg (pop ,args-var)))
           (locally (declare (type simple-string arg))
             (cond
               ((and (>= (length arg) 3)
                     (char= (schar arg 0) #\-)
                     (char= (schar arg 1) #\-))
                (,dispatch-fn (subseq arg 2)))
               ((and (>= (length arg) 1)
                     (char= (schar arg 0) #\-))
                (let ((tail (subseq arg 1)))
                  (if (zerop (length tail))
                      (,dispatch-fn "-")
                      (loop for c across tail
                            do (,dispatch-fn (string c))))))
               (t
                (incf ,pos-count)
                ,(if arg-clause
                     `(let ((arg arg)) ,@(cdr arg-clause))
                     `(print-help-and-quit
                       "Unexpected positional argument: ~a"
                       arg)))))))))

  (defun cli-dispatch-and-loop-form (args-var pos-count key arg-name
                                     required-trackers program-clauses)
    `(flet ((dispatch (,arg-name)
              (declare (type simple-string ,arg-name))
              (let ((,key (match-option ,arg-name)))
                (case ,key
                  ,@(cli-required-markers required-trackers))
                (case ,key
                  ,@(cli-option-clauses program-clauses)
                  (t (print-help-and-quit "Unknown option: ~a" ,arg-name))))))
       ,(cli-main-loop-form args-var pos-count 'dispatch program-clauses))))

(defmacro with-cli-parsing ((args-var options-list &key (min-args 0))
                            &body program-clauses)
  (multiple-value-bind (dispatch-clauses required-trackers)
      (cli-parse-options (symbol-value options-list))
    (let ((key       (gensym "KEY"))
          (arg-name  (gensym "STR"))
          (pos-count (gensym "POS-COUNT")))
      `(let ((,pos-count 0)
             ,@(cli-required-bindings required-trackers))
         (declare (type fixnum ,pos-count))
         (macrolet ((match-option (s)
                      `(string-case:string-case (,s :default nil)
                         ,@',dispatch-clauses)))
           ,(cli-dispatch-and-loop-form
             args-var pos-count key arg-name
             required-trackers program-clauses)
           ,@(cli-required-checks required-trackers)
           (when (< ,pos-count ,min-args)
             (print-help-and-quit
              "Program requires at least ~a positional argument(s)."
              ,min-args)))))))

;;; with-cli-parsing.cl ends here
