;;; kernels/lines-and-words.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Lines and words combined counting kernels (Generic, AVX2, AVX-512).

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))

(declaim (inline count-lines-and-words-ascii count-lines-and-words-utf8
                 count-lines-and-words-ascii-avx2 count-lines-and-words-utf8-avx2
                 #+avx512 count-lines-and-words-512
                 #+avx512 count-lines-and-words-ascii-avx512
                 #+avx512 count-lines-and-words-utf8-avx512))


;;; Generic implementation

(def-swar-kernel count-lines-and-words-ascii (sap size ws-init-state) :lines t :words t)

(defun count-lines-and-words-utf8 (sap size ws-init-state)
  (count-lines-and-words-ascii sap size ws-init-state))


;;; AVX2 implementation

#+avx2
(progn
  (defun count-lines-and-words-ascii-avx2 (sap size ws-init-state)
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 127)
      for i of-type fixnum from 0 below loop-end by 128

      with 0x0  of-type u8.32 = (u8.32 #x00)
      with 0x20 of-type u8.32 = (u8.32 #x20)
      with 0x0A of-type u8.32 = (u8.32 #x0A)

      with wa of-type u64.4 = (u64.4 0)
      with la of-type u64.4 = (u64.4 0)

      with ws-prev of-type u8.32 = (u8.32 ws-init-state)

      for c1 = (u8.32-sap-ref sap (+ i 0))
      for c2 = (u8.32-sap-ref sap (+ i 32))
      for c3 = (u8.32-sap-ref sap (+ i 64))
      for c4 = (u8.32-sap-ref sap (+ i 96))

      do
         (macrolet ((process-chunk (curr prev)
                      `(let* ((curr ,curr) (prev ,prev))
                         (let* ((ctrl  (u8.32-sat- (u8.32- curr 9) 4))
                                (ws (u8.32-or (u8.32= ctrl 0x0) (u8.32= curr 0x20)))
                                (ws-shift (u8.32-alignr ws (u8.32-permute128 prev ws #x21) 15))
                                (wmask    (u8.32-andc1 ws ws-shift))
                                (lmask (u8.32= curr 0x0A)))
                           (values wmask lmask ws)))))

           (multiple-value-bind (wm lm prev) (process-chunk c1 ws-prev)
             (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                    la (u64.4+ la (u8.32-sad lm 0x0))
                    ws-prev prev))
           (multiple-value-bind (wm lm prev) (process-chunk c2 ws-prev)
             (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                    la (u64.4+ la (u8.32-sad lm 0x0))
                    ws-prev prev))
           (multiple-value-bind (wm lm prev) (process-chunk c3 ws-prev)
             (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                    la (u64.4+ la (u8.32-sad lm 0x0))
                    ws-prev prev))
           (multiple-value-bind (wm lm prev) (process-chunk c4 ws-prev)
             (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                    la (u64.4+ la (u8.32-sad lm 0x0))
                    ws-prev prev)))
      finally
         (return
           (loop for j from loop-end below size
                 with words of-type fixnum    = (sum-lanes wa)
                 with lines of-type fixnum    = (sum-lanes la)
                 with prev-ws of-type boolean = (logbitp 31 (u8.32-movemask ws-prev))
                 with tlines of-type fixnum   = 0
                 with twords of-type fixnum   = 0
                 for byte of-type fixnum      = (sb-sys:sap-ref-8 sap j)
                 for curr-ws of-type boolean  = (or (= byte 32) (<= 9 byte 13))
                 do
                    (when (= byte 10) (incf tlines))
                    (when (and (not curr-ws) prev-ws) (incf twords))
                    (setf prev-ws curr-ws)
                 finally
                    (return (values (the fixnum (+ lines tlines))
                                    (the fixnum (+ words twords))
                                    nil))))))

  (defun count-lines-and-words-utf8-avx2 (sap size ws-init-state)
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (count-lines-and-words-ascii-avx2 sap size ws-init-state)))

#-avx2
(progn
  (defun count-lines-and-words-ascii-avx2 (sap size ws-init-state)
    (count-lines-and-words-ascii sap size ws-init-state))
  (defun count-lines-and-words-utf8-avx2 (sap size ws-init-state)
    (count-lines-and-words-utf8 sap size ws-init-state)))


;;; AVX-512 implementation

#+avx512
(progn
  (defun count-lines-and-words-512 (sap size ws-init-state)
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (ws-lut +ws-lut+)
          (lf-vec +lf-vec+)
          (prev-was-ws (if (zerop ws-init-state) 0 1))
          (la0 0) (la1 0) (la2 0) (la3 0)
          (wa0 0) (wa1 0) (wa2 0) (wa3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 ws-lut lf-vec)
               (type (unsigned-byte 64) la0 la1 la2 la3 wa0 wa1 wa2 wa3 prev-was-ws))
      (macrolet ((chunk (offset la wa)
                   `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                           (ws-mask (ws-bits-512 c ws-lut))
                           (lf-mask (line-bits-512 c lf-vec))
                           (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                           (starts  (logandc2 shifted ws-mask)))
                      (declare (type (unsigned-byte 64) ws-mask lf-mask shifted starts))
                      (setf prev-was-ws (ash ws-mask -63))
                      (incf ,la (popcount64 lf-mask))
                      (incf ,wa (popcount64 starts)))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   la0 wa0)
          (chunk 64  la1 wa1)
          (chunk 128 la2 wa2)
          (chunk 192 la3 wa3)
          (chunk 256 la0 wa0)
          (chunk 320 la1 wa1)
          (chunk 384 la2 wa2)
          (chunk 448 la3 wa3)))
      (let ((lines (+ la0 la1 la2 la3))
            (words (+ wa0 wa1 wa2 wa3)))
        (declare (type (unsigned-byte 64) lines words))
        (loop for j of-type fixnum from loop-end below size
              for byte = (sb-sys:sap-ref-8 sap j)
              for is-ws = (or (= byte 32) (<= 9 byte 13))
              do (when (= byte 10) (incf lines))
                 (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
                 (setf prev-was-ws (if is-ws 1 0)))
        (values (the fixnum lines) (the fixnum words) nil))))

  (defun count-lines-and-words-utf8-avx512 (sap size ws-init-state)
    (count-lines-and-words-512 sap size ws-init-state))

  (defun count-lines-and-words-ascii-avx512 (sap size ws-init-state)
    (count-lines-and-words-512 sap size ws-init-state)))

;;; kernels/lines-and-words.cl ends here
