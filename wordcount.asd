(eval-when (:compile-toplevel :load-toplevel :execute)
  (unless (find-package :wordcount.system)
    (defpackage :wordcount.system
      (:use :common-lisp :asdf))))

#+sbcl
(when (member :avx512 (symbol-value 'sb-impl:+internal-features+))
  (unless (uiop:getenv "WC_NO_SIMD")
    (pushnew :avx512 *features*)))

(in-package :wordcount.system)

(defclass src (cl-source-file)
  ((type :initform "cl")))

(defsystem :wordcount
  :description "Wordcount program"
  :author "Arthur Miller <arthur.miller@live.com>"
  :licence "GPLv3.0"
  :version "0.1.0"
  :build-operation program-op
  :build-pathname "wc"
  :entry-point "wordcount::main"
  :components ((:module "src"
                :serial t
                :components ((src "packages")
                             (src "common")
                             (:module "kernels"
                              :serial t
                              :components ((src "common")
                                           (src "lines")
                                           (src "words")
                                           (src "chars")
                                           (src "lines-and-words")
                                           (src "lines-and-chars")
                                           (src "words-and-chars")
                                           (src "lines-words-and-chars")))
                             (src "dispatch")
                             (src "scheduler")
                             (src "api")
                             (src "wc-driver")
                             (src "cli-options")
                             (src "main"))))

  :depends-on ("uiop"
               "sb-simd"
               "with-user-abort"))
