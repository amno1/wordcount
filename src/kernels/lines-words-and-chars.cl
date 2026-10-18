;;; kernels/lines-words-and-chars.cl
;;; Copyright (C) 2026  Arthur Miller
;;; Lines, words, and characters combined counting kernels (Generic, AVX2, AVX-512).

#-sbcl
(error "This file requires SBCL compiler.")

(in-package :wc)

(declaim (optimize (speed 3) (safety 0)))

(declaim (inline count-lines-words-and-chars-ascii
                 count-lines-words-and-chars-utf8
                 count-lines-words-and-chars-utf8-strict
                 count-lines-words-and-chars-ascii-avx2
                 count-lines-words-and-chars-utf8-avx2
                 count-lines-words-and-chars-utf8-strict-avx2
                 #+avx512 count-lines-words-and-chars-ascii-avx512
                 #+avx512 count-lines-words-and-chars-utf8-avx512
                 #+avx512 count-lines-words-and-chars-utf8-strict-avx512))


;;; Generic implementation

(defun count-lines-words-and-chars-ascii (sap size ws-init-state)
  (values (nth-value 0 (count-lines sap size))
          (nth-value 1 (count-words-ascii sap size ws-init-state))
          size))

(defun count-lines-words-and-chars-utf8 (sap size ws-init-state)
  (values (nth-value 0 (count-lines sap size))
          (nth-value 1 (count-words-ascii sap size ws-init-state))
          (nth-value 2 (count-chars-utf8 sap size))))

(defun count-lines-words-and-chars-utf8-strict (sap size ws-init-state &optional (ed-init-state 0))
  (values (nth-value 0 (count-lines sap size))
          (nth-value 1 (count-words-ascii sap size ws-init-state))
          (nth-value 2 (count-chars-utf8-strict sap size ed-init-state))))


;;; AVX2 implementation

#+avx2
(progn
  (defun count-lines-words-and-chars-utf8-strict-avx2 (sap size ws-init-state &optional (ed-init-state 0))
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state ed-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 127)
      for i of-type fixnum from 0 below loop-end by 128

      ;; masks
      with 0x0  of-type u8.32 = (u8.32 #x00)
      with 0x0A of-type u8.32 = (u8.32 #x0A)
      with 0x20 of-type u8.32 = (u8.32 #x20)
      with 0x80 of-type u8.32 = (u8.32 #x80)
      with 0xED of-type u8.32 = (u8.32 #xED)

      ;; accumulators
      with la of-type u64.4 = (u64.4 0)
      with wa of-type u64.4 = (u64.4 0)
      with ca of-type u64.4 = (u64.4 0)

      ;; carry
      with ws-prev of-type u8.32 = (u8.32 ws-init-state)
      with ed-prev of-type u8.32 = (u8.32 (if (zerop ed-init-state) 0 #xFF))

      ;; chunks
      for c1 = (u8.32-sap-ref sap (+ i 0))
      for c2 = (u8.32-sap-ref sap (+ i 32))
      for c3 = (u8.32-sap-ref sap (+ i 64))
      for c4 = (u8.32-sap-ref sap (+ i 96))

      do
         (macrolet ((process-chunk (curr prev-ws prev-ed)
                      `(let* ((curr ,curr) (prev-ws ,prev-ws) (prev-ed ,prev-ed))
                         (let* (;; masked lines
                                (lmask (u8.32= curr 0x0A))

                                ;; whitespace mask [9,13] and 32
                                (ctrl  (u8.32-sat- (u8.32- curr 9) 4))
                                (ws    (u8.32-or (u8.32= ctrl 0x0) (u8.32= curr 0x20)))
                                (wssh  (u8.32-alignr ws (u8.32-permute128 prev-ws ws #x21) 15))
                                (wmask (u8.32-andc1 ws wssh))

                                ;; strict utf8 validation (range + surrogate check)
                                (ascii (u8.32= (u8.32-and curr 0x80) 0x0))
                                (vlead (u8.32= (u8.32-sat- (u8.32- curr 194) 50) 0x0))
                                (ed    (u8.32= curr 0xED))
                                (edsh  (u8.32-alignr ed (u8.32-permute128 prev-ed ed #x21) 15))
                                (foll  (u8.32= (u8.32-sat- (u8.32- curr #xA0) 31) 0x0))
                                (bad   (u8.32-and edsh foll))
                                (cmask (u8.32-andc1 bad (u8.32-or ascii vlead))))
                           (values lmask wmask cmask ws ed)))))

           (multiple-value-bind (lm wm cm ws ed) (process-chunk c1 ws-prev ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws ed-prev ed))
           (multiple-value-bind (lm wm cm ws ed) (process-chunk c2 ws-prev ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws ed-prev ed))
           (multiple-value-bind (lm wm cm ws ed) (process-chunk c3 ws-prev ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws ed-prev ed))
           (multiple-value-bind (lm wm cm ws ed) (process-chunk c4 ws-prev ed-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws ed-prev ed)))
      finally
         (let* ((lines (sum-lanes la))
                (words (sum-lanes wa))
                (chars (sum-lanes ca))
                (prev-ws (logbitp 31 (u8.32-movemask ws-prev)))
                (prev-ed (logbitp 31 (u8.32-movemask ed-prev)))
                (tlines 0) (twords 0) (tchars 0))
           (declare (type fixnum lines words chars tlines twords tchars))

           (loop for j from loop-end below size
                 for byte of-type fixnum    = (sb-sys:sap-ref-8 sap j)
                 for curr of-type boolean   = (or (= byte 32) (<= 9 byte 13))
                 for ascii of-type boolean  = (<= 0 byte 127)
                 for vlead of-type boolean  = (<= 194 byte 244)
                 for bad of-type boolean    = (and prev-ed (<= #xA0 byte #xBF))
                 do
                    (when (= byte 10) (incf tlines))
                    (when (and (not curr) prev-ws) (incf twords))
                    (when (and (or ascii vlead) (not bad)) (incf tchars))
                    (setf prev-ws curr prev-ed (= byte #xED)))

           (return (values (the fixnum (+ lines tlines))
                           (the fixnum (+ words twords))
                           (the fixnum (+ chars tchars)))))))

  (defun count-lines-words-and-chars-utf8-avx2 (sap size ws-init-state)
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (loop
      with loop-end of-type fixnum = (logandc2 size 127)
      for i of-type fixnum from 0 below loop-end by 128

      ;; masks
      with 0x0 of-type u8.32  = (u8.32 #x00)
      with 0x0A of-type u8.32 = (u8.32 #x0A)
      with 0x20 of-type u8.32 = (u8.32 #x20)
      with 0xC0 of-type u8.32 = (u8.32 #xC0)
      with 0x80 of-type u8.32 = (u8.32 #x80)
      with 0xFF of-type u8.32 = (u8.32 #xFF)

      ;; accumulators
      with la of-type u64.4 = (u64.4 0)
      with wa of-type u64.4 = (u64.4 0)
      with ca of-type u64.4 = (u64.4 0)

      ;; carry
      with ws-prev of-type u8.32 = (u8.32 ws-init-state)

      ;; chunks
      for p1 = (u8.32-sap-ref sap (+ i 0))
      for p2 = (u8.32-sap-ref sap (+ i 32))
      for p3 = (u8.32-sap-ref sap (+ i 64))
      for p4 = (u8.32-sap-ref sap (+ i 96))
      do
         (macrolet ((process-chunk (curr prev)
                      `(let* ((curr ,curr) (prev ,prev))
                         (let* (;; lines mask
                                (lmask (u8.32= curr 0x0A))

                                ;; whitespace mask ([9,13] and 32)
                                (ctrl (u8.32-sat- (u8.32- curr 9) 4))
                                (ws   (u8.32-or (u8.32= ctrl 0x0) (u8.32= curr 0x20)))

                                ;; crossing
                                (wssh  (u8.32-alignr ws (u8.32-permute128 prev ws #x21) 15))
                                (wmask (u8.32-andc1 ws wssh))

                                ;; fast utf8: NOT (byte AND #xC0 == #x80)
                                (cont  (u8.32= (u8.32-and curr 0xC0) 0x80))
                                (cmask (u8.32-andc1 cont 0xFF)))
                           (values lmask wmask cmask ws)))))

           (multiple-value-bind (lm wm cm ws) (process-chunk p1 ws-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws))
           (multiple-value-bind (lm wm cm ws) (process-chunk p2 ws-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws))
           (multiple-value-bind (lm wm cm ws) (process-chunk p3 ws-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws))
           (multiple-value-bind (lm wm cm ws) (process-chunk p4 ws-prev)
             (setf la (u64.4+ la (u8.32-sad lm 0x0))
                   wa (u64.4+ wa (u8.32-sad wm 0x0))
                   ca (u64.4+ ca (u8.32-sad cm 0x0))
                   ws-prev ws)))
      finally
         (return
           (loop
             for j from loop-end below size
             for byte of-type fixnum  = (sb-sys:sap-ref-8 sap j)
             for curr of-type boolean = (or (= byte 32) (<= 9 byte 13))

             with lines of-type fixnum  = (sum-lanes la)
             with words of-type fixnum  = (sum-lanes wa)
             with chars of-type fixnum  = (sum-lanes ca)
             with prev of-type boolean  = (logbitp 31 (u8.32-movemask ws-prev))
             with tlines of-type fixnum = 0
             with twords of-type fixnum = 0
             with tchars of-type fixnum = 0
             do
                (when (= byte 10) (incf tlines))
                (when (and (not curr) prev) (incf twords))
                (when (/= (logand byte #xC0) #x80) (incf tchars))
                (setf prev curr)
             finally
                (return (values (the fixnum (+ lines tlines))
                                (the fixnum (+ words twords))
                                (the fixnum (+ chars tchars)))))))))

#-avx2
(progn
  (defun count-lines-words-and-chars-ascii-avx2 (sap size ws-init-state)
    (count-lines-words-and-chars-ascii sap size ws-init-state))
  (defun count-lines-words-and-chars-utf8-avx2 (sap size ws-init-state)
    (count-lines-words-and-chars-utf8 sap size ws-init-state))
  (defun count-lines-words-and-chars-utf8-strict-avx2 (sap size ws-init-state &optional (ed-init-state 0))
    (count-lines-words-and-chars-utf8-strict sap size ws-init-state ed-init-state)))

#+avx2
(defun count-lines-words-and-chars-ascii-avx2 (sap size ws-init-state)
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (optimize (speed 3) (safety 0)))
  (multiple-value-bind (lines words) (count-lines-and-words-ascii-avx2 sap size ws-init-state)
    (values lines words size)))


;;; AVX-512 implementation

#+avx512
(progn
  (defun count-lines-words-and-chars-utf8-strict-avx512 (sap size ws-init-state &optional (ed-init-state 0))
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state ed-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (ws-lut +ws-lut+)
          (lf-vec +lf-vec+)
          (v80 +utf8-v80+)
          (v0 +utf8-v0+)
          (v194 +utf8-v194+)
          (v244 +utf8-v244+)
          (ved +utf8-ved+)
          (va0 +utf8-va0+)
          (vbf +utf8-vbf+)
          (prev-was-ws (if (zerop ws-init-state) 0 1))
          (prev-was-ed (if (zerop ed-init-state) 0 1))
          (la0 0) (la1 0) (la2 0) (la3 0)
          (wa0 0) (wa1 0) (wa2 0) (wa3 0)
          (ca0 0) (ca1 0) (ca2 0) (ca3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 ws-lut lf-vec v80 v0 v194 v244 ved va0 vbf)
               (type (unsigned-byte 64) la0 la1 la2 la3 wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3 prev-was-ws prev-was-ed))
      (macrolet ((chunk (offset la wa ca)
                   `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                           (ws-mask (ws-bits-512 c ws-lut))
                           (lf-mask (line-bits-512 c lf-vec))
                           (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                           (starts  (logandc2 shifted ws-mask)))
                      (multiple-value-bind (valid ed)
                          (utf8-strict-bits-512 c prev-was-ed v80 v0 v194 v244 ved va0 vbf)
                        (setf prev-was-ws (ash ws-mask -63))
                        (setf prev-was-ed (ash ed -63))
                        (incf ,la (popcount64 lf-mask))
                        (incf ,wa (popcount64 starts))
                        (incf ,ca (popcount64 valid))))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   la0 wa0 ca0)
          (chunk 64  la1 wa1 ca1)
          (chunk 128 la2 wa2 ca2)
          (chunk 192 la3 wa3 ca3)
          (chunk 256 la0 wa0 ca0)
          (chunk 320 la1 wa1 ca1)
          (chunk 384 la2 wa2 ca2)
          (chunk 448 la3 wa3 ca3)))
      (let ((lines (+ la0 la1 la2 la3))
            (words (+ wa0 wa1 wa2 wa3))
            (chars (+ ca0 ca1 ca2 ca3)))
        (declare (type (unsigned-byte 64) lines words chars))
        (loop for j of-type fixnum from loop-end below size
              for byte = (sb-sys:sap-ref-8 sap j)
              for is-ws = (or (= byte 32) (<= 9 byte 13))
              for ascii = (<= 0 byte 127)
              for vlead = (<= 194 byte 244)
              for bad   = (and (= prev-was-ed 1) (<= #xA0 byte #xBF))
              do (when (= byte 10) (incf lines))
                 (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
                 (when (and (or ascii vlead) (not bad)) (incf chars))
                 (setf prev-was-ws (if is-ws 1 0)
                       prev-was-ed (if (= byte #xED) 1 0)))
        (values (the fixnum lines) (the fixnum words) (the fixnum chars)))))

  (defun count-lines-words-and-chars-utf8-avx512 (sap size ws-init-state)
    (declare (type fixnum size)
             (type (unsigned-byte 8) ws-init-state)
             (type sb-sys:system-area-pointer sap)
             (optimize (speed 3) (safety 0)))
    (let ((loop-end (logandc2 size 511))
          (ws-lut +ws-lut+)
          (lf-vec +lf-vec+)
          (c0-vec +cont-c0+)
          (80-vec +cont-80+)
          (prev-was-ws (if (zerop ws-init-state) 0 1))
          (la0 0) (la1 0) (la2 0) (la3 0)
          (wa0 0) (wa1 0) (wa2 0) (wa3 0)
          (ca0 0) (ca1 0) (ca2 0) (ca3 0))
      (declare (type fixnum loop-end)
               (type avx512bw:u8.64 ws-lut lf-vec c0-vec 80-vec)
               (type (unsigned-byte 64) la0 la1 la2 la3 wa0 wa1 wa2 wa3 ca0 ca1 ca2 ca3 prev-was-ws))
      (macrolet ((chunk (offset la wa ca)
                   `(let* ((c       (avx512bw:u8.64-sap-ref sap (+ i ,offset)))
                           (ws-mask (ws-bits-512 c ws-lut))
                           (lf-mask (line-bits-512 c lf-vec))
                           (shifted (logior (ldb (byte 64 0) (ash ws-mask 1)) prev-was-ws))
                           (starts  (logandc2 shifted ws-mask)))
                      (declare (type (unsigned-byte 64) ws-mask lf-mask shifted starts))
                      (setf prev-was-ws (ash ws-mask -63))
                      (incf ,la (popcount64 lf-mask))
                      (incf ,wa (popcount64 starts))
                      (incf ,ca (popcount64
                                 (logand #xFFFFFFFFFFFFFFFF
                                         (lognot (cont-bits-512 c c0-vec 80-vec))))))))
        (loop for i of-type fixnum from 0 below loop-end by 512 do
          (chunk 0   la0 wa0 ca0)
          (chunk 64  la1 wa1 ca1)
          (chunk 128 la2 wa2 ca2)
          (chunk 192 la3 wa3 ca3)
          (chunk 256 la0 wa0 ca0)
          (chunk 320 la1 wa1 ca1)
          (chunk 384 la2 wa2 ca2)
          (chunk 448 la3 wa3 ca3)))
      (let ((lines (+ la0 la1 la2 la3))
            (words (+ wa0 wa1 wa2 wa3))
            (chars (+ ca0 ca1 ca2 ca3)))
        (declare (type (unsigned-byte 64) lines words chars))
        (loop for j of-type fixnum from loop-end below size
              for byte = (sb-sys:sap-ref-8 sap j)
              for is-ws = (or (= byte 32) (<= 9 byte 13))
              do (when (= byte 10) (incf lines))
                 (when (and (not is-ws) (= prev-was-ws 1)) (incf words))
                 (when (/= (logand byte #xC0) #x80) (incf chars))
                 (setf prev-was-ws (if is-ws 1 0)))
        (values (the fixnum lines) (the fixnum words) (the fixnum chars)))))

  (defun count-lines-words-and-chars-ascii-avx512 (sap size ws-init-state)
    (multiple-value-bind (lines words) (count-lines-and-words-512 sap size ws-init-state)
      (values lines words size))))

;;; kernels/lines-words-and-chars.cl ends here
