;;; kernels/lines-and-chars.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Lines and characters combined counting kernels (Generic, AVX2, AVX-512).

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))

(declaim (inline count-lines-and-chars-ascii-generic
                 count-lines-and-chars-utf8-generic
                 count-lines-and-chars-utf8-strict-generic
                 count-lines-and-chars-ascii
                 count-lines-and-chars-utf8
                 count-lines-and-chars-utf8-strict
                 #+avx512 count-lines-and-chars-ascii-avx512
                 #+avx512 count-lines-and-chars-utf8-512
                 #+avx512 count-lines-and-chars-utf8-avx512
                 #+avx512 count-lines-and-chars-utf8-strict-512
                 #+avx512 count-lines-and-chars-utf8-strict-avx512))


;;; Generic implementation

(defun count-lines-and-chars-ascii-generic (sap size)
  (values (nth-value 0 (count-lines-generic sap size)) nil size))

(defun count-lines-and-chars-utf8-generic (sap size)
  (values (nth-value 0 (count-lines-generic sap size))
          nil
          (nth-value 2 (count-chars-utf8-generic sap size))))

(defun count-lines-and-chars-utf8-strict-generic (sap size &optional (ed-init-state 0))
  (values (nth-value 0 (count-lines-generic sap size))
          nil
          (nth-value 2 (count-chars-utf8-strict-generic sap size ed-init-state))))


;;; AVX2 implementation

(defun count-lines-and-chars-ascii (sap size)
  (values (count-lines-ascii sap size) nil size))

#+avx2
(progn
  (defun count-lines-and-chars-utf8 (sap size)
    (declare (type fixnum size)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 127)
      for i of-type fixnum from 0 below loop-end by 128

      ;; masks
      with 0x0  of-type u8.32 = (u8.32 #x00)
      with 0xFF of-type u8.32 = (u8.32 #xFF)
      with 0xC0 of-type u8.32 = (u8.32 #xC0)
      with 0x80 of-type u8.32 = (u8.32 #x80)
      with 0x0A of-type u8.32 = (u8.32 #x0A)

      ;; accumulators
      with la of-type u64.4 = (u64.4 0)
      with ca of-type u64.4 = (u64.4 0)

      ;; chunks
      for c1 = (u8.32-sap-ref sap (+ i 0))
      for c2 = (u8.32-sap-ref sap (+ i 32))
      for c3 = (u8.32-sap-ref sap (+ i 64))
      for c4 = (u8.32-sap-ref sap (+ i 96))

      do
         (macrolet ((process-chunk (c)
                      `(let* ((c ,c))
                         (let* ((linep (u8.32= c 0x0A))
                                (contp (u8.32= (u8.32-and c 0xC0) 0x80))
                                (charp (u8.32-andc1 contp 0xFF)))
                           (values (u8.32-sad linep 0x0) (u8.32-sad charp 0x0))))))

           (multiple-value-bind (l c) (process-chunk c1)
             (psetf la (u64.4+ la l) ca (u64.4+ ca c)))
           (multiple-value-bind (l c) (process-chunk c2)
             (psetf la (u64.4+ la l) ca (u64.4+ ca c)))
           (multiple-value-bind (l c) (process-chunk c3)
             (psetf la (u64.4+ la l) ca (u64.4+ ca c)))
           (multiple-value-bind (l c) (process-chunk c4)
             (psetf la (u64.4+ la l) ca (u64.4+ ca c))))

      finally
         (let* ((lines (sum-lanes la))
                (chars (sum-lanes ca))
                (tlines 0) (tchars 0))
           (declare (type fixnum lines chars tlines tchars))

           (loop for j from loop-end below size
                 for byte = (sb-sys:sap-ref-8 sap j)
                 do
                    (when (= byte 10) (incf tlines))
                    (when (/= (logand byte #xC0) #x80) (incf tchars)))

           (return (values (the fixnum (+ lines tlines))
                           nil
                           (the fixnum (+ chars tchars)))))))

  (defun count-lines-and-chars-utf8-strict (sap size &optional (ed-init-state 0))
    (declare (type fixnum size)
             (type (unsigned-byte 8) ed-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 127)
      for i of-type fixnum from 0 below loop-end by 128

      ;; masks
      with 0x0  of-type u8.32 = (u8.32 #x00)
      with 0x0A of-type u8.32 = (u8.32 #x0A)
      with 0x80 of-type u8.32 = (u8.32 #x80)
      with 0xED of-type u8.32 = (u8.32 #xED)

      ;; accumulators
      with la of-type u64.4 = (u64.4 0)
      with ca of-type u64.4 = (u64.4 0)

      ;; Carry
      with ed-prev of-type u8.32 = (u8.32 (if (zerop ed-init-state) 0 #xFF))

      for p1 = (u8.32-sap-ref sap (+ i 0))
      for p2 = (u8.32-sap-ref sap (+ i 32))
      for p3 = (u8.32-sap-ref sap (+ i 64))
      for p4 = (u8.32-sap-ref sap (+ i 96))

      do
         (macrolet ((process-chunk (chunk prev-ed)
                      `(let* ((chunk ,chunk) (prev-ed ,prev-ed))
                         (let* ((line  (u8.32= chunk 0x0A))
                                (ascii (u8.32= (u8.32-and chunk 0x80) 0x0))
                                (vlead (u8.32= (u8.32-sat- (u8.32- chunk 194) 50) 0x0))
                                (ed    (u8.32= chunk 0xED))
                                (ed-shift (u8.32-alignr ed (u8.32-permute128 prev-ed ed #x21) 15))
                                (foll  (u8.32= (u8.32-sat- (u8.32- chunk #xA0) 31) 0x0))
                                (bad   (u8.32-and ed-shift foll))
                                (valid (u8.32-andc1 bad (u8.32-or ascii vlead))))
                           (values line valid ed)))))

           (multiple-value-bind (lm cm ed) (process-chunk p1 ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ed-prev ed))
           (multiple-value-bind (lm cm ed) (process-chunk p2 ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ed-prev ed))
           (multiple-value-bind (lm cm ed) (process-chunk p3 ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ed-prev ed))
           (multiple-value-bind (lm cm ed) (process-chunk p4 ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ed-prev ed)))

      finally
         (let* ((lines (sum-lanes la))
                (chars (sum-lanes ca))
                (prev  (logbitp 31 (u8.32-movemask ed-prev)))
                (tlines 0) (tchars 0))
           (declare (type fixnum lines chars tlines tchars))

           (loop for j from loop-end below size
                 for byte = (sb-sys:sap-ref-8 sap j)
                 do (let* ((ascii (<= 0 byte 127))
                           (vlead (<= 194 byte 244))
                           (ed    (= byte #xED))
                           (bad   (and prev (<= #xA0 byte #xBF))))
                      (when (= byte 10) (incf tlines))
                      (when (and (or ascii vlead) (not bad)) (incf tchars))
                      (setf prev ed)))

           (return (values (the fixnum (+ lines tlines))
                           nil
                           (the fixnum (+ chars tchars))))))))

#-avx2
(progn
  (defun count-lines-and-chars-utf8 (sap size)
    (count-lines-and-chars-utf8-generic sap size))
  (defun count-lines-and-chars-utf8-strict (sap size &optional (ed-init-state 0))
    (count-lines-and-chars-utf8-strict-generic sap size ed-init-state)))


;;; AVX-512 implementation

#+avx512
(progn
  (defun count-lines-and-chars-ascii-avx512 (sap size)
    (values (nth-value 0 (count-lines-ascii-avx512 sap size)) nil size))

  (defun count-lines-and-chars-utf8-512 (sap size)
    (declare (type fixnum size)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (lf-vec +lf-vec+)
          (c0-vec +cont-c0+)
          (80-vec +cont-80+)
          (la0 0) (la1 0) (la2 0) (la3 0)
          (ca0 0) (ca1 0) (ca2 0) (ca3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 lf-vec c0-vec 80-vec)
               (type (unsigned-byte 64) la0 la1 la2 la3 ca0 ca1 ca2 ca3))
      (macrolet ((chunk (offset la ca)
                   `(let* ((c (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                           (non-cont (logand #xFFFFFFFFFFFFFFFF (lognot (cont-bits-512 c c0-vec 80-vec)))))
                      (incf ,la (popcount64 (line-bits-512 c lf-vec)))
                      (incf ,ca (popcount64 non-cont)))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   la0 ca0)
          (chunk 64  la1 ca1)
          (chunk 128 la2 ca2)
          (chunk 192 la3 ca3)
          (chunk 256 la0 ca0)
          (chunk 320 la1 ca1)
          (chunk 384 la2 ca2)
          (chunk 448 la3 ca3)))
      (let ((lines (+ la0 la1 la2 la3))
            (chars (+ ca0 ca1 ca2 ca3)))
        (declare (type (unsigned-byte 64) lines chars))
        (loop for j of-type fixnum from loop-end below size
              for byte = (sb-sys:sap-ref-8 sap j)
              do (when (= byte 10) (incf lines))
                 (when (/= (logand byte #xC0) #x80) (incf chars)))
        (values (the fixnum lines) nil (the fixnum chars)))))

  (defun count-lines-and-chars-utf8-avx512 (sap size)
    (count-lines-and-chars-utf8-512 sap size))

  (defun count-lines-and-chars-utf8-strict-512 (sap size &optional (ed-init-state 0))
    (declare (type fixnum size)
             (type (unsigned-byte 8) ed-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (lf-vec +lf-vec+)
          (v80 +utf8-v80+)
          (v0 +utf8-v0+)
          (v194 +utf8-v194+)
          (v244 +utf8-v244+)
          (ved +utf8-ved+)
          (va0 +utf8-va0+)
          (vbf +utf8-vbf+)
          (prev-was-ed (if (zerop ed-init-state) 0 1))
          (la0 0) (la1 0) (la2 0) (la3 0)
          (ca0 0) (ca1 0) (ca2 0) (ca3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 lf-vec v80 v0 v194 v244 ved va0 vbf)
               (type (unsigned-byte 64) la0 la1 la2 la3 ca0 ca1 ca2 ca3 prev-was-ed))
      (macrolet ((chunk (offset la ca)
                   `(let ((c (avx512bw:u8.64-sap-ref sap (+ i ,offset))))
                      (multiple-value-bind (valid ed)
                          (utf8-strict-bits-512 c prev-was-ed v80 v0 v194 v244 ved va0 vbf)
                        (setf prev-was-ed (ash ed -63))
                        (incf ,la (popcount64 (line-bits-512 c lf-vec)))
                        (incf ,ca (popcount64 valid))))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   la0 ca0)
          (chunk 64  la1 ca1)
          (chunk 128 la2 ca2)
          (chunk 192 la3 ca3)
          (chunk 256 la0 ca0)
          (chunk 320 la1 ca1)
          (chunk 384 la2 ca2)
          (chunk 448 la3 ca3)))
      (let ((lines (+ la0 la1 la2 la3))
            (chars (+ ca0 ca1 ca2 ca3)))
        (declare (type (unsigned-byte 64) lines chars))
        (loop for j of-type fixnum from loop-end below size
              for byte = (sb-sys:sap-ref-8 sap j)
              for ascii = (<= 0 byte 127)
              for vlead = (<= 194 byte 244)
              for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
              do (when (= byte 10) (incf lines))
                 (when (and (or ascii vlead) (not bad)) (incf chars))
                 (setf prev-was-ed (if (= byte #xED) 1 0)))
        (values (the fixnum lines) nil (the fixnum chars)))))

  (defun count-lines-and-chars-utf8-strict-avx512 (sap size &optional (ed-init-state 0))
    (count-lines-and-chars-utf8-strict-512 sap size ed-init-state)))

;;; kernels/lines-and-chars.cl ends here
