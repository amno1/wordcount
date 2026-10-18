;;; kernels/chars.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Character counting kernels (Generic, AVX2, AVX-512) for ASCII, lenient UTF-8, and strict UTF-8.

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))

(declaim (inline count-chars-ascii count-chars-utf8 count-chars-utf8-strict
                 count-chars-ascii-avx2 count-chars-utf8-avx2 count-chars-utf8-strict-avx2
                 #+avx512 count-chars-ascii-avx512
                 #+avx512 count-chars-utf8-avx512
                 #+avx512 count-chars-utf8-strict-avx512))


;;; Generic SWAR implementation

(defun count-chars-ascii (sap size)
  (declare (ignore sap)
           (type fixnum size)
           (optimize (speed 3) (safety 0)))
  (values nil nil size))

(defun count-chars-utf8 (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 7))
        (chars 0))
    (declare (type fixnum loop-end chars))
    (loop for i of-type fixnum from 0 below loop-end by 8
          do (incf chars (swar-utf8-count-fast (sb-sys:sap-ref-64 sap i))))
    (values nil nil
            (the fixnum
                 (loop for j of-type fixnum from loop-end below size
                       count (/= (logand (sb-sys:sap-ref-8 sap j) #xC0) #x80)
                       into tail
                       finally (return (+ chars tail)))))))

(defun count-chars-utf8-strict (sap size &optional (ed-init-state 0))
  (declare (type fixnum size)
           (type (unsigned-byte 8) ed-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 7))
        (chars 0)
        (prev-ed-hi (if (zerop ed-init-state) 0 #x80)))
    (declare (type fixnum loop-end chars)
             (type (unsigned-byte 8) prev-ed-hi))
    (loop for i of-type fixnum from 0 below loop-end by 8
          for chunk of-type (unsigned-byte 64) = (sb-sys:sap-ref-64 sap i)
          do (multiple-value-bind (bad new-prev-ed-hi) (swar-bad-surrogate-mask chunk prev-ed-hi)
               (incf chars (logcount (logandc2 (swar-utf8-valid-lead-mask chunk) bad)))
               (setf prev-ed-hi new-prev-ed-hi)))
    (values nil nil
            (the fixnum
                 (loop for j of-type fixnum from loop-end below size
                       with prev-ed of-type boolean = (not (zerop prev-ed-hi))
                       for byte of-type (unsigned-byte 8) = (sb-sys:sap-ref-8 sap j)
                       for ascii = (<= byte 127)
                       for vlead = (<= 194 byte 244)
                       for bad   = (and prev-ed (<= #xA0 byte #xBF))
                       do
                          (when (and (or ascii vlead) (not bad)) (incf chars))
                          (setf prev-ed (= byte #xED))
                       finally (return chars))))))


;;; AVX2 implementation

(defun count-chars-ascii-avx2 (sap size)
  (declare (ignore sap)
           (type fixnum size)
           (optimize (speed 3) (safety 0)))
  (values nil nil size))

#+avx2
(progn
  (defun count-chars-utf8-avx2 (sap size)
    (declare (type fixnum size)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 255)
      for i of-type fixnum from 0 below loop-end by 256
      with 0x0 of-type u8.32 = (u8.32 #x00)
      with 0xC of-type u8.32 = (u8.32 #xC0)
      with 0x8 of-type u8.32 = (u8.32 #x80)
      with 0xF of-type u8.32 = (u8.32 #xFF)
      with a1 of-type u64.4 = (u64.4 0)
      with a2 of-type u64.4 = (u64.4 0)
      with a3 of-type u64.4 = (u64.4 0)
      with a4 of-type u64.4 = (u64.4 0)
      with a5 of-type u64.4 = (u64.4 0)
      with a6 of-type u64.4 = (u64.4 0)
      with a7 of-type u64.4 = (u64.4 0)
      with a8 of-type u64.4 = (u64.4 0)

      for c1 of-type u8.32 = (u8.32-sap-ref sap (+ i 0))
      for c2 of-type u8.32 = (u8.32-sap-ref sap (+ i 32))
      for c3 of-type u8.32 = (u8.32-sap-ref sap (+ i 64))
      for c4 of-type u8.32 = (u8.32-sap-ref sap (+ i 96))
      for c5 of-type u8.32 = (u8.32-sap-ref sap (+ i 128))
      for c6 of-type u8.32 = (u8.32-sap-ref sap (+ i 160))
      for c7 of-type u8.32 = (u8.32-sap-ref sap (+ i 192))
      for c8 of-type u8.32 = (u8.32-sap-ref sap (+ i 224))
      do
         (macrolet ((process-chunk (chunk)
                      `(let* ((chunk ,chunk))
                         (let* ((contp (u8.32= (u8.32-and chunk 0xC) 0x8))
                                (charp (u8.32-andc1 contp 0xF)))
                           (u8.32-sad charp 0x0)))))
           (setf a1 (u64.4+ a1 (process-chunk c1)))
           (setf a2 (u64.4+ a2 (process-chunk c2)))
           (setf a3 (u64.4+ a3 (process-chunk c3)))
           (setf a4 (u64.4+ a4 (process-chunk c4)))
           (setf a5 (u64.4+ a5 (process-chunk c5)))
           (setf a6 (u64.4+ a6 (process-chunk c6)))
           (setf a7 (u64.4+ a7 (process-chunk c7)))
           (setf a8 (u64.4+ a8 (process-chunk c8))))
      finally
         (let* ((sum (u64.4+ a1 a2 a3 a4 a5 a6 a7 a8))
                (chars (sum-lanes sum))
                (tail  (loop for j from loop-end below size
                             count (/= (logand (sb-sys:sap-ref-8 sap j) #xC0) #x80))))
           (declare (type fixnum chars tail))
           (return (values nil nil (the fixnum (+ chars tail)))))))

  (defun count-chars-utf8-strict-avx2 (sap size &optional (ed-init-state 0))
    (declare (type fixnum size)
             (type (unsigned-byte 8) ed-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 127)
      for i of-type fixnum from 0 below loop-end by 128
      with 0x0  of-type u8.32 = (u8.32 #x00)
      with 0x80 of-type u8.32 = (u8.32 #x80)
      with 0xED of-type u8.32 = (u8.32 #xED)
      with a1 of-type u64.4 = (u64.4 0)
      with a2 of-type u64.4 = (u64.4 0)
      with a3 of-type u64.4 = (u64.4 0)
      with a4 of-type u64.4 = (u64.4 0)
      with ed-prev-chunk of-type u8.32 = (u8.32 (if (zerop ed-init-state) 0 #xFF))

      for c1 = (u8.32-sap-ref sap (+ i 0))
      for c2 = (u8.32-sap-ref sap (+ i 32))
      for c3 = (u8.32-sap-ref sap (+ i 64))
      for c4 = (u8.32-sap-ref sap (+ i 96))
      do
         (macrolet ((validate-and-count (curr prev)
                      `(let* ((curr ,curr) (prev ,prev))
                         (let* ((ascii (u8.32= (u8.32-and curr 0x80) 0x0))
                                (vlead (u8.32= (u8.32-sat- (u8.32- curr 194) 50) 0x0))
                                (ed    (u8.32= curr 0xED))
                                (ed-prev (u8.32-alignr ed (u8.32-permute128 prev ed #x21) 15))
                                (follow (u8.32= (u8.32-sat- (u8.32- curr #xA0) 31) 0x0))
                                (bad-surr (u8.32-and ed-prev follow))
                                (valid-start (u8.32-andc1 bad-surr (u8.32-or ascii vlead))))
                           (values (u8.32-sad valid-start 0x0) ed)))))

           (multiple-value-bind (cnt ed) (validate-and-count c1 ed-prev-chunk)
             (setf a1 (u64.4+ a1 cnt) ed-prev-chunk ed))
           (multiple-value-bind (cnt ed) (validate-and-count c2 ed-prev-chunk)
             (setf a2 (u64.4+ a2 cnt) ed-prev-chunk ed))
           (multiple-value-bind (cnt ed) (validate-and-count c3 ed-prev-chunk)
             (setf a3 (u64.4+ a3 cnt) ed-prev-chunk ed))
           (multiple-value-bind (cnt ed) (validate-and-count c4 ed-prev-chunk)
             (setf a4 (u64.4+ a4 cnt) ed-prev-chunk ed)))
      finally
         (return
           (loop for j from loop-end below size
                 with tail of-type fixnum = 0
                 with chars   = (sum-lanes (u64.4+ a1 a2 a3 a4))
                 with prev-ed = (logbitp 31 (u8.32-movemask ed-prev-chunk))
                 for byte    = (sb-sys:sap-ref-8 sap j)
                 for ascii   = (<= 0 byte 127)
                 for vlead   = (<= 194 byte 244)
                 for ed      = (= byte #xED)
                 for follow  = (<= #xA0 byte #xBF)
                 for bad     = (and prev-ed follow)
                 do
                    (when (and (or ascii vlead) (not bad)) (incf tail))
                    (setf prev-ed ed)
                 finally
                    (return (values nil nil (the fixnum (+ chars tail)))))))))

#-avx2
(progn
  (defun count-chars-utf8-avx2 (sap size)
    (count-chars-utf8 sap size))
  (defun count-chars-utf8-strict-avx2 (sap size &optional (ed-init-state 0))
    (count-chars-utf8-strict sap size ed-init-state)))


;;; AVX-512 implementation

#+avx512
(progn
  (defun count-chars-ascii-avx512 (sap size)
    (declare (ignore sap))
    (values nil nil size))

  (defun count-chars-utf8-avx512 (sap size)
    (declare (type fixnum size)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (c0-vec +cont-c0+)
          (80-vec +cont-80+)
          (ca0 0) (ca1 0) (ca2 0) (ca3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 c0-vec 80-vec)
               (type (unsigned-byte 64) ca0 ca1 ca2 ca3))
      (macrolet ((chunk (offset ca)
                   `(let* ((c (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                           (non-cont (logand #xFFFFFFFFFFFFFFFF
                                             (lognot (cont-bits-512 c c0-vec 80-vec)))))
                      (incf ,ca (popcount64 non-cont)))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   ca0)
          (chunk 64  ca1)
          (chunk 128 ca2)
          (chunk 192 ca3)
          (chunk 256 ca0)
          (chunk 320 ca1)
          (chunk 384 ca2)
          (chunk 448 ca3)))
      (let ((chars (+ ca0 ca1 ca2 ca3)))
        (declare (type (unsigned-byte 64) chars))
        (loop for j of-type fixnum from loop-end below size
              when (/= (logand (sb-sys:sap-ref-8 sap j) #xC0) #x80)
              do (incf chars))
        (values nil nil (the fixnum chars)))))

  (defun count-chars-utf8-strict-avx512 (sap size &optional (ed-init-state 0))
    (declare (type fixnum size)
             (type (unsigned-byte 8) ed-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (v80  +utf8-v80+)
          (v0   +utf8-v0+)
          (v194 +utf8-v194+)
          (v244 +utf8-v244+)
          (ved  +utf8-ved+)
          (va0  +utf8-va0+)
          (vbf  +utf8-vbf+)
          (prev-was-ed (if (zerop ed-init-state) 0 1))
          (ca0 0) (ca1 0) (ca2 0) (ca3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 v80 v0 v194 v244 ved va0 vbf)
               (type (unsigned-byte 64) ca0 ca1 ca2 ca3 prev-was-ed))
      (macrolet ((chunk (offset ca)
                   `(multiple-value-bind (valid ed)
                        (utf8-strict-bits-512
                         (avx512bw:u8.64-sap-ref sap (+ i ,offset))
                         prev-was-ed v80 v0 v194 v244 ved va0 vbf)
                      (setf prev-was-ed (ash ed -63))
                      (incf ,ca (popcount64 valid)))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   ca0)
          (chunk 64  ca1)
          (chunk 128 ca2)
          (chunk 192 ca3)
          (chunk 256 ca0)
          (chunk 320 ca1)
          (chunk 384 ca2)
          (chunk 448 ca3)))
      (let ((chars (+ ca0 ca1 ca2 ca3)))
        (declare (type (unsigned-byte 64) chars))
        (loop for j of-type fixnum from loop-end below size
              for byte = (sb-sys:sap-ref-8 sap j)
              for ascii = (<= 0 byte 127)
              for vlead = (<= 194 byte 244)
              for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
              do (when (and (or ascii vlead) (not bad)) (incf chars))
                 (setf prev-was-ed (if (= byte #xED) 1 0)))
        (values nil nil (the fixnum chars))))))

;;; kernels/chars.cl ends here
