;;; Standalone correctness test: base SWAR kernels vs.
;;; sb-simd-based "-AVX2" kernels and "-AVX512" kernels.
;;; Uses PARACHUTE (DEFINE-TEST/IS), one test per kernel.
;;; Does not need the full wordcount ASDF system (no lparallel etc).
;;; Invoke from the wordcount/ root (see makefile's TEST target), not
;;; from within tests/ -- every relative path below is root-relative.

(require :asdf)
(require :sb-simd)
(require :sb-posix)

(load (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname)))
(ql:quickload :parachute :silent t)

;; packages.cl's AVX512BW/AVX512F local-nicknames are gated on :AVX512
;; being pushed onto *FEATURES* normally done once by wordcount.asd's
;; own eval-when, which this standalone test never loads. Add it here
;; so packages.cl sees the same feature it would under the real build.
#+sbcl
(progn
  (when (member :avx2 (symbol-value 'sb-impl:+internal-features+))
    (unless (uiop:getenv "WC_NO_SIMD")
      (pushnew :avx2 *features*)))
  (when (member :avx512 (symbol-value 'sb-impl:+internal-features+))
    (unless (uiop:getenv "WC_NO_SIMD")
      (pushnew :avx512 *features*))))

;; packages.cl :uses with-user-abort just for a condition type we don't
;; need for these correctness checks; stub it so packages.cl loads.
(defpackage #:with-user-abort (:use #:cl) (:export #:user-abort))
(load (compile-file "src/packages.cl"))
(load (compile-file "src/common.cl"))
(load (compile-file "src/kernels/common.cl"))
(load (compile-file "src/kernels/lines.cl"))
(load (compile-file "src/kernels/words.cl"))
(load (compile-file "src/kernels/chars.cl"))
(load (compile-file "src/kernels/lines-and-words.cl"))
(load (compile-file "src/kernels/lines-and-chars.cl"))
(load (compile-file "src/kernels/words-and-chars.cl"))
(load (compile-file "src/kernels/lines-words-and-chars.cl"))
(load (compile-file "src/dispatch.cl"))
(load (compile-file "src/scheduler.cl"))
(load (compile-file "src/api.cl"))

(in-package :wc)

;; The base SWAR kernels, under their own clean names, are the
;; reference that the "-AVX2" and "-AVX512" siblings get checked against.

(defmacro with-sap-from-bytes ((sap-var bytes) &body body)
  (let ((v (gensym)))
    `(let ((,v (coerce ,bytes '(simple-array (unsigned-byte 8) (*)))))
       (sb-sys:with-pinned-objects (,v)
         (let ((,sap-var (sb-sys:vector-sap ,v)))
           ,@body)))))

;; PARACHUTE's report echoes every IS form verbatim, pass or fail,
;; fine for the small literal args gage3/src/format's tests use, but
;; our "arguments" are byte buffers up to megabytes long. REGISTER
;; stores a (BYTES . MORE-ARGS) case under a small integer id, so rows
;; below can reference it as e.g. "(count-words-ascii-agree-p 42)"
;; instead of dumping the buffer itself into the report.
(defvar *cases* (make-array 0 :adjustable t :fill-pointer 0))

(defun register (bytes &rest more-args)
  (vector-push-extend (cons bytes more-args) *cases*)
  (1- (fill-pointer *cases*)))

;; DEF-KERNEL-TEST: BASE-NAME is the clean base SWAR kernel name
;; (the reference). Defines <BASE-NAME>-AGREE-P, true iff its
;; "-AVX2" and "-AVX512" siblings both return exactly what the
;; reference does for the case-id given, mirroring KERNEL-CALL,
;; then a PARACHUTE test named BASE-NAME checking every id in CASE-IDS.
(defmacro def-kernel-test (base-name case-ids)
  (let* ((s (string base-name))
         (checker (intern (concatenate 'string s "-AGREE-P")))
         (avx2    (intern (concatenate 'string s "-AVX2")))
         (avx512  (intern (concatenate 'string s "-AVX512"))))
    `(progn
       (defun ,checker (case-id)
         (destructuring-bind (bytes . more-args) (aref *cases* case-id)
           (with-sap-from-bytes (sap bytes)
             (let ((expected (multiple-value-list
                              (apply #',base-name sap (length bytes) more-args))))
               (and (or (not (fboundp ',avx2))
                        (equal expected (multiple-value-list (apply (fdefinition ',avx2) sap (length bytes) more-args))))
                    (or (not (fboundp ',avx512))
                        (equal expected (multiple-value-list (apply (fdefinition ',avx512) sap (length bytes) more-args)))))))))
       (parachute:define-test ,base-name
         (dolist (id ,case-ids)
           (parachute:is eql t (,checker id)))))))

(defun random-buffer (n &key (seed 1))
  (let ((state (sb-ext:seed-random-state seed))
        (chars #(32 9 10 11 12 13 65 97 46 44 48 49 50 51 33 63 10 32 32 9)))
    (make-array n :element-type '(unsigned-byte 8)
                  :initial-contents (loop repeat n collect (aref chars (random (length chars) state))))))

(defun utf8-buffer (n &key (seed 2))
  ;; mix of ascii and 2/3-byte utf8 sequences (well-formed) plus some
  ;; whitespace, for the non-strict utf8 (continuation-byte) counters.
  (let ((state (sb-ext:seed-random-state seed))
        (out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop while (< (fill-pointer out) n)
          do (case (random 4 state)
               (0 (vector-push-extend 32 out))
               (1 (vector-push-extend (+ 65 (random 26 state)) out))
               (2 (vector-push-extend #xC3 out) (vector-push-extend #xA9 out)) ; e-acute
               (3 (vector-push-extend #xE2 out) (vector-push-extend #x82 out) (vector-push-extend #xAC out)))) ; euro sign
    (subseq out 0 (min n (length out)))))

(defun utf8-strict-buffer (n &key (seed 3))
  ;; Same well-formed mix as UTF8-BUFFER, but also occasionally injects
  ;; exactly the byte patterns STRICT validation treats differently
  ;; from the lenient continuation-byte heuristic: an 0xED lead
  ;; followed by an A0-BF byte (the illegal UTF-8 encoding of a
  ;; surrogate half -- STRICT must not count it as a character start;
  ;; lenient counts it since A0-BF isn't a continuation byte), and
  ;; lead bytes outside the valid C2-F4 range (STRICT rejects; lenient
  ;; doesn't check lead-byte validity at all).
  (let ((state (sb-ext:seed-random-state seed))
        (out (make-array 0 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (loop while (< (fill-pointer out) n)
          do (case (random 7 state)
               (0 (vector-push-extend 32 out))
               (1 (vector-push-extend (+ 65 (random 26 state)) out))
               (2 (vector-push-extend #xC3 out) (vector-push-extend #xA9 out))
               (3 (vector-push-extend #xE2 out) (vector-push-extend #x82 out) (vector-push-extend #xAC out))
               (4 (vector-push-extend #xED out) (vector-push-extend (+ #xA0 (random 32 state)) out)) ; illegal surrogate
               (5 (vector-push-extend (+ #x80 (random 66 state)) out)) ; C0/C1 or bare continuation: invalid lead
               (6 (vector-push-extend (+ #xF5 (random 11 state)) out)))) ; F5-FF: invalid lead
    (subseq out 0 (min n (length out)))))

(defun file-prefix (path &optional (limit 5000000))
  (when (probe-file path)
    (with-open-file (s path :element-type '(unsigned-byte 8))
      (let* ((len (min (file-length s) limit))
             (buf (make-array len :element-type '(unsigned-byte 8))))
        (read-sequence buf s)
        (format t "including ~A first bytes of ~A~%" len path)
        buf))))


;; row sources, shared by every kernel family below

;; BUFFERS is a list of (BYTES . WS-STATE) conses. IDS registers each
;; buffer alone (for kernels with no WS-INIT-STATE argument); WS-IDS
;; registers each buffer paired with its WS-STATE (for kernels that
;; take one).
(defun ids (buffers) (loop for entry in buffers collect (register (car entry))))
(defun ws-ids (buffers) (loop for (bytes . ws) in buffers collect (register bytes ws)))

(defparameter *ascii-buffers*
  (append
   (loop for n in (append '(0 1 2 8 9 12 13 20 32 63 64 65 100 127 128 129 191 192 193
                             255 256 257 1000 4096 4097)
                           (loop for k from 1 to 40 collect k))
         nconc (loop for ws in '(0 255) collect (cons (random-buffer n :seed (+ n ws 1)) ws)))
   (list (cons (make-array 0 :element-type '(unsigned-byte 8)) 0)
         (cons (make-array 200 :element-type '(unsigned-byte 8) :initial-element 32) 0)
         (cons (make-array 200 :element-type '(unsigned-byte 8) :initial-element 65) 0)
         (cons (make-array 200 :element-type '(unsigned-byte 8) :initial-element 10) 0)
         (cons (coerce (loop for i from 0 below 300 collect (if (evenp i) 32 65)) '(vector (unsigned-byte 8))) 0)
         (cons (coerce (loop for i from 0 below 300 collect (if (evenp i) 32 65)) '(vector (unsigned-byte 8))) 255))
   ;; whitespace run straddling exactly the 64-byte chunk boundary
   (let ((buf (make-array 130 :element-type '(unsigned-byte 8) :initial-element 65)))
     (loop for i from 60 below 68 do (setf (aref buf i) 32))
     (list (cons buf 0) (cons buf 255)))
   (let ((buf (file-prefix "tests/plato1g.txt")))
     (when buf (list (cons buf 0) (cons buf 255))))))

(defparameter *utf8-buffers*
  (append
   (loop for n in '(0 1 3 10 30 63 64 65 100 127 128 129 191 192 193 200 255 256 257 1000)
         nconc (loop for ws in '(0 255) collect (cons (utf8-buffer n :seed (+ n ws 2)) ws)))
   ;; whitespace run straddling the 128-byte chunk boundary
   (let ((buf (make-array 260 :element-type '(unsigned-byte 8) :initial-element 65)))
     (loop for i from 124 below 132 do (setf (aref buf i) 32))
     (list (cons buf 0) (cons buf 255)))
   (let ((buf (file-prefix "tests/plato1g.txt")))
     (when buf (list (cons buf 0) (cons buf 255))))))

(defparameter *utf8-strict-buffers*
  (append
   (loop for n in '(0 1 3 10 30 63 64 65 100 127 128 129 191 192 193 200 255 256 257 1000)
         nconc (loop for ws in '(0 255) collect (cons (utf8-strict-buffer n :seed (+ n ws 3)) ws)))
   ;; whitespace/surrogate runs straddling the 128-byte chunk boundary
   (let ((buf (make-array 260 :element-type '(unsigned-byte 8) :initial-element 65)))
     (loop for i from 124 below 132 do (setf (aref buf i) 32))
     (list (cons buf 0) (cons buf 255)))
   (let ((buf (make-array 260 :element-type '(unsigned-byte 8) :initial-element 65)))
     (setf (aref buf 126) #xED (aref buf 127) #xA0)   ; illegal surrogate straddling the boundary
     (list (cons buf 0)))
   (let ((buf (make-array 260 :element-type '(unsigned-byte 8) :initial-element 65)))
     (setf (aref buf 127) #xED (aref buf 128) #xA0)   ; the ED itself is the last byte of chunk 0
     (list (cons buf 0)))
   (let ((buf (file-prefix "tests/plato1g.txt")))
     (when buf (list (cons buf 0) (cons buf 255))))))


;; one PARACHUTE test per kernel

(defparameter *ascii-ids* (ids *ascii-buffers*))
(defparameter *ascii-ws-ids* (ws-ids *ascii-buffers*))
(defparameter *utf8-ids* (ids *utf8-buffers*))
(defparameter *utf8-ws-ids* (ws-ids *utf8-buffers*))
(defparameter *utf8-strict-ids* (ids *utf8-strict-buffers*))
(defparameter *utf8-strict-ws-ids* (ws-ids *utf8-strict-buffers*))

(def-kernel-test count-lines-ascii *ascii-ids*)
(def-kernel-test count-words-ascii *ascii-ws-ids*)
(def-kernel-test count-chars-ascii *ascii-ids*)
(def-kernel-test count-lines-and-words-ascii *ascii-ws-ids*)
(def-kernel-test count-lines-and-chars-ascii *ascii-ids*)
(def-kernel-test count-words-and-chars-ascii *ascii-ws-ids*)
(def-kernel-test count-lines-words-and-chars-ascii *ascii-ws-ids*)

(def-kernel-test count-chars-utf8 *utf8-ids*)
(def-kernel-test count-words-utf8 *utf8-ws-ids*)
(def-kernel-test count-lines-and-words-utf8 *utf8-ws-ids*)
(def-kernel-test count-lines-and-chars-utf8 *utf8-ids*)
(def-kernel-test count-words-and-chars-utf8 *utf8-ws-ids*)
(def-kernel-test count-lines-words-and-chars-utf8 *utf8-ws-ids*)

(def-kernel-test count-chars-utf8-strict *utf8-strict-ids*)
(def-kernel-test count-lines-and-chars-utf8-strict *utf8-strict-ids*)
(def-kernel-test count-words-and-chars-utf8-strict *utf8-strict-ws-ids*)
(def-kernel-test count-lines-words-and-chars-utf8-strict *utf8-strict-ws-ids*)

(parachute:define-test strict-utf8-chunk-boundary-carry
  (let* ((prefix (make-array 63 :element-type '(unsigned-byte 8) :initial-element 65))
         (suffix (make-array 63 :element-type '(unsigned-byte 8) :initial-element 66))
         ;; [63 bytes 'A'] + [#xED] + [#xA0] + [63 bytes 'B'] = 128 bytes
         (full (coerce (append (coerce prefix 'list) '(#xED #xA0) (coerce suffix 'list))
                       '(simple-array (unsigned-byte 8) (*))))
         (chunk1 (subseq full 0 64)) ; ends with #xED
         (chunk2 (subseq full 64)))  ; begins with #xA0
    (with-sap-from-bytes (sap full)
      (let ((total-chars (nth-value 2 (count-chars-utf8-strict sap (length full) 0))))
        (with-sap-from-bytes (c1-sap chunk1)
          (with-sap-from-bytes (c2-sap chunk2)
            (let* ((c1-chars (nth-value 2 (count-chars-utf8-strict c1-sap (length chunk1) 0)))
                   (c2-chars (nth-value 2 (count-chars-utf8-strict c2-sap (length chunk2) 1))))
              ;; The sum with threaded carry matches total
              (parachute:is = total-chars (+ c1-chars c2-chars))
              ;; All backends agree on chunk2 with init-ed = 1
              #+avx2
              (parachute:is eql t (equal (multiple-value-list (count-chars-utf8-strict c2-sap (length chunk2) 1))
                                         (multiple-value-list (count-chars-utf8-strict-avx2 c2-sap (length chunk2) 1))))
              #+avx512
              (parachute:is eql t (equal (multiple-value-list (count-chars-utf8-strict c2-sap (length chunk2) 1))
                                         (multiple-value-list (count-chars-utf8-strict-avx512 c2-sap (length chunk2) 1)))))))))))

(parachute:define-test public-api-smoke-test
  (let ((text (sb-ext:string-to-octets (format nil "hello world~%second line~%third line~%"))))
    (with-sap-from-bytes (sap text)
      (let ((len (length text)))
        ;; SAP tier
        (parachute:is = 3 (count-lines-sap sap len))
        (parachute:is = 1 (length (multiple-value-list (count-lines-sap sap len))))
        (parachute:is = 6 (count-words-sap sap len))
        (parachute:is = len (count-chars-ascii-sap sap len))
        (parachute:is = len (count-bytes-sap sap len :implementation :generic))
        (multiple-value-bind (l w) (count-lines-and-words-sap sap len)
          (parachute:is = 3 l)
          (parachute:is = 6 w))
        (multiple-value-bind (l w c) (count-lines-words-and-chars-ascii-sap sap len)
          (parachute:is = 3 l)
          (parachute:is = 6 w)
          (parachute:is = len c)))))
  ;; Path tier on wordcount.asd (standardized 5-value return: lines words chars bytes err)
  (multiple-value-bind (lines words chars bytes err) (count-lines "wordcount.asd")
    (parachute:is eql t (null err))
    (parachute:is eql t (> lines 0))
    (parachute:is = 0 words)
    (parachute:is = 0 chars)
    (parachute:is eql t (> bytes 0)))
  (multiple-value-bind (lines words chars bytes err) (count-words "wordcount.asd")
    (parachute:is eql t (null err))
    (parachute:is = 0 lines)
    (parachute:is eql t (> words 0))
    (parachute:is = 0 chars)
    (parachute:is eql t (> bytes 0)))
  (multiple-value-bind (l w c b err) (count-lines-words-and-chars-utf8-path "wordcount.asd")
    (parachute:is eql t (null err))
    (parachute:is eql t (> l 0))
    (parachute:is eql t (> w 0))
    (parachute:is eql t (> c 0))
    (parachute:is = b (nth-value 3 (count-lines "wordcount.asd"))))
  ;; FD tier: count-bytes-fd must preserve file offset on seekable files
  (let ((fd (sb-posix:open "wordcount.asd" sb-posix:o-rdonly)))
    (unwind-protect
         (progn
           (parachute:is = 0 (sb-posix:lseek fd 0 sb-posix:seek-cur))
           (multiple-value-bind (l w c b err) (count-bytes-fd fd)
             (parachute:is eql t (null err))
             (parachute:is = 0 l)
             (parachute:is = 0 w)
             (parachute:is = 0 c)
             (parachute:is eql t (> b 0))
             ;; Crucial check: fd offset must not have been moved to EOF
             (parachute:is = 0 (sb-posix:lseek fd 0 sb-posix:seek-cur))))
      (sb-posix:close fd))))

(let ((result (parachute:test :wc)))
  (sb-ext:exit :code (if (eq (parachute:status result) :passed) 0 1)))

;;; test-avx512-kernels.lisp ends here
