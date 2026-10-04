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
                :components ((src "packages")
                             (src "common")
                             (src "kernels-avx2")
                             (src "kernels-generic")
                             (src "kernels-avx512")
                             (src "wc-driver")
                             (src "with-cli-parsing")
                             (src "cli-options")
                             (src "main"))))

  :depends-on ("asdf"
               "uiop"
               "sb-simd"
               "string-case"
               "with-user-abort"))
