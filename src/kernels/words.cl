;;; kernels/words.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Word counting kernels (Generic, AVX2, AVX-512).

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))

(declaim (inline count-words-ascii count-words-utf8
                 count-words-ascii-avx2 count-words-utf8-avx2
                 #+avx512 count-words-512
                 #+avx512 count-words-ascii-avx512
                 #+avx512 count-words-utf8-avx512))


;;; Generic SWAR implementation

(def-swar-kernel count-words-ascii (sap size ws-init-state) :words t)

(defun count-words-utf8 (sap size ws-init-state)
  (count-words-ascii sap size ws-init-state))


;;; AVX2 implementation

#+avx2
(progn
  (defun count-words-ascii-avx2 (sap size ws-init-state)
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 127)
      for i of-type fixnum from 0 below loop-end by 128
      with 0x0 of-type u8.32 = (u8.32 #x00)
      with 0x20 of-type u8.32 = (u8.32 #x20)
      with a1 of-type u64.4 = (u64.4 0)
      with a2 of-type u64.4 = (u64.4 0)
      with a3 of-type u64.4 = (u64.4 0)
      with a4 of-type u64.4 = (u64.4 0)
      with ws-prev of-type u8.32 = (u8.32 ws-init-state)
      for c1 = (u8.32-sap-ref sap (+ i 0))
      for c2 = (u8.32-sap-ref sap (+ i 32))
      for c3 = (u8.32-sap-ref sap (+ i 64))
      for c4 = (u8.32-sap-ref sap (+ i 96))
      do
         (macrolet ((process-chunk (curr prev)
                      `(let* ((curr ,curr) (prev ,prev))
                         (let* ((ctrl (u8.32-sat- (u8.32- curr 9) 4))
                                (ws   (u8.32-or (u8.32= ctrl 0x0) (u8.32= curr 0x20)))
                                (ws-shift (u8.32-alignr ws (u8.32-permute128 prev ws #x21) 15))
                                (wmask    (u8.32-andc1 ws ws-shift)))
                           (values wmask ws)))))
           (multiple-value-bind (wmask prev) (process-chunk c1 ws-prev)
             (setf a1 (u64.4+ a1 (u8.32-sad wmask 0x0)) ws-prev prev))
           (multiple-value-bind (wmask prev) (process-chunk c2 ws-prev)
             (setf a2 (u64.4+ a2 (u8.32-sad wmask 0x0)) ws-prev prev))
           (multiple-value-bind (wmask prev) (process-chunk c3 ws-prev)
             (setf a3 (u64.4+ a3 (u8.32-sad wmask 0x0)) ws-prev prev))
           (multiple-value-bind (wmask prev) (process-chunk c4 ws-prev)
             (setf a4 (u64.4+ a4 (u8.32-sad wmask 0x0)) ws-prev prev)))
      finally
         (return
           (loop for j from loop-end below size
                 with tail of-type fixnum  = 0
                 with words of-type fixnum = (sum-lanes (u64.4+ a1 a2 a3 a4))
                 with prev of-type boolean = (logbitp 31 (u8.32-movemask ws-prev))
                 for byte = (sb-sys:sap-ref-8 sap j)
                 for curr = (or (= byte 32) (<= 9 byte 13))
                 do
                    (and prev (not curr) (incf tail))
                    (setf prev curr)
                 finally
                    (return (values nil (the fixnum (+ words tail)) nil))))))

  (defun count-words-utf8-avx2 (sap size ws-init-state)
    (count-words-ascii-avx2 sap size ws-init-state)))

#-avx2
(progn
  (defun count-words-ascii-avx2 (sap size ws-init-state)
    (count-words-ascii sap size ws-init-state))
  (defun count-words-utf8-avx2 (sap size ws-init-state)
    (count-words-utf8 sap size ws-init-state)))


;;; AVX-512 implementation

#+avx512
(progn
  (defun count-words-512 (sap size ws-init-state)
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (ws-lut +ws-lut+)
          (prev-was-ws (if (zerop ws-init-state) 0 1))
          (wa0 0) (wa1 0) (wa2 0) (wa3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 ws-lut)
               (type (unsigned-byte 64) wa0 wa1 wa2 wa3 prev-was-ws))
      (macrolet ((chunk (offset wa)
                   `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                           (ws-mask (ws-bits-512 c ws-lut))
                           (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                           (starts  (logandc2 shifted ws-mask)))
                      (setf prev-was-ws (ash ws-mask -63))
                      (incf ,wa (popcount64 starts)))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   wa0)
          (chunk 64  wa1)
          (chunk 128 wa2)
          (chunk 192 wa3)
          (chunk 256 wa0)
          (chunk 320 wa1)
          (chunk 384 wa2)
          (chunk 448 wa3)))
      (let ((words (+ wa0 wa1 wa2 wa3)))
        (declare (type (unsigned-byte 64) words))
        (loop for j of-type fixnum from loop-end below size
              for byte = (sb-sys:sap-ref-8 sap j)
              for is-ws = (or (= byte 32) (<= 9 byte 13))
              do (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
                 (setf prev-was-ws (if is-ws 1 0)))
        (values nil (the fixnum words) nil))))

  (defun count-words-ascii-avx512 (sap size ws-init-state)
    (count-words-512 sap size ws-init-state))

  (defun count-words-utf8-avx512 (sap size ws-init-state)
    (count-words-512 sap size ws-init-state)))

;;; kernels/words.cl ends here
