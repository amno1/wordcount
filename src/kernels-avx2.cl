;; kernels-avx2.cl
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
#-sbcl
(error "This file requires SBCL compiler.")

(declaim (optimize (speed 3) (safety 0)))

(in-package :wc)

(declaim (inline count-lines-words-and-chars-utf8
                 count-lines-words-and-chars-ascii
                 count-lines-utf8 count-words-utf8 count-chars-utf8
                 count-lines-ascii count-words-ascii count-chars-ascii
                 count-lines-and-words-utf8 count-words-and-chars-utf8 count-lines-and-chars-utf8
                 count-lines-and-words-ascii count-words-and-chars-ascii count-lines-and-chars-ascii))

;; helpers

(declaim (inline sum-lanes))
(defun sum-lanes (acc)
  (declare (type u64.4 acc))
  (let* ((lo (u64.2-from-u64.4 acc 0))
         (hi (u64.2-from-u64.4 acc 1))
         (sum (u64.2+ lo hi))
         (max most-positive-fixnum))
    (declare (type u64.2 lo hi sum))
    (the fixnum
         (truncate
          (+ (logand (sse4.1:u64.2-elt sum 0) max)
             (logand (sse4.1:u64.2-elt sum 1) max))
          255))))

;; count lines

(declaim (inline count-lines))
(defun count-lines (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 255)))
    (declare (type fixnum loop-end))
    (macrolet ((accum (a c)
                 `(setf ,a (u64.4+ ,a (u8.32-sad (u8.32= ,c 0xA) 0x0)))))
      (loop
        for i of-type fixnum from 0 below loop-end by 256

        ;; masks
        with 0x0 of-type u8.32 = (u8.32  0)
        with 0xA of-type u8.32 = (u8.32 10)

        ;; accumulators
        with a1 of-type u64.4 = (u64.4 0)
        with a2 of-type u64.4 = (u64.4 0)
        with a3 of-type u64.4 = (u64.4 0)
        with a4 of-type u64.4 = (u64.4 0)
        with a5 of-type u64.4 = (u64.4 0)
        with a6 of-type u64.4 = (u64.4 0)
        with a7 of-type u64.4 = (u64.4 0)
        with a8 of-type u64.4 = (u64.4 0)

        ;; chunks
        for c1 of-type u8.32 = (u8.32-sap-ref sap (+ i 0))
        for c2 of-type u8.32 = (u8.32-sap-ref sap (+ i 32))
        for c3 of-type u8.32 = (u8.32-sap-ref sap (+ i 64))
        for c4 of-type u8.32 = (u8.32-sap-ref sap (+ i 96))
        for c5 of-type u8.32 = (u8.32-sap-ref sap (+ i 128))
        for c6 of-type u8.32 = (u8.32-sap-ref sap (+ i 160))
        for c7 of-type u8.32 = (u8.32-sap-ref sap (+ i 192))
        for c8 of-type u8.32 = (u8.32-sap-ref sap (+ i 224))
        do
           (accum a1 c1) (accum a2 c2) (accum a3 c3) (accum a4 c4)
           (accum a5 c5) (accum a6 c6) (accum a7 c7) (accum a8 c8)
        finally
           (let ((lines (sum-lanes (u64.4+ a1 a2 a3 a4 a5 a6 a7 a8)))
                 (tail-lines (loop for j from loop-end below size
                                   count (= (sb-sys:sap-ref-8 sap j) 10))))
             (declare (type fixnum lines tail-lines))
             (return (values (the fixnum (+ lines tail-lines)) nil nil)))))))

;; we only check \n = LF = 10 (0xA)
(defun count-lines-utf8 (sap size)
  (count-lines sap size))

(defun count-lines-ascii (sap size)
  (count-lines sap size))

;; count words

(declaim (inline count-words-ascii))
(defun count-words-ascii (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (loop
    with loop-end of-type fixnum = (logandc2 size 127)
    for i of-type fixnum from 0 below loop-end by 128

    ;; masks
    with 0x00 of-type u8.32 = (u8.32 #x00)
    with 0x04 of-type u8.32 = (u8.32 #x04)
    with 0x09 of-type u8.32 = (u8.32 #x09)
    with 0x20 of-type u8.32 = (u8.32 #x20)

    ;; accumulators
    with a1 of-type u64.4 = (u64.4 0)
    with a2 of-type u64.4 = (u64.4 0)
    with a3 of-type u64.4 = (u64.4 0)
    with a4 of-type u64.4 = (u64.4 0)

    ;; carry
    with ws-prev of-type u8.32 = (u8.32 ws-init-state)

    ;; chunks
    for c1 of-type u8.32 = (u8.32-sap-ref sap (+ i   0))
    for c2 of-type u8.32 = (u8.32-sap-ref sap (+ i  32))
    for c3 of-type u8.32 = (u8.32-sap-ref sap (+ i  64))
    for c4 of-type u8.32 = (u8.32-sap-ref sap (+ i  96))
    do
       (macrolet ((process-chunk (chunk prev)
                    `(let* ((chunk ,chunk) (prev ,prev))
                       (declare (type u8.32 chunk prev))
                       (let* ((shifted    (u8.32- chunk 0x09))
                              (sat        (u8.32-sat- shifted 0x04))
                              (ctrl-mask  (u8.32= sat 0x00))
                              (space-mask (u8.32= chunk 0x20))
                              (ws         (u8.32-or ctrl-mask space-mask))
                              (ws-perm    (u8.32-permute128   prev ws #x21))
                              (ws-curr    (u8.32-alignr       ws ws-perm 15))
                              (words      (u8.32-andc1        ws ws-curr)))
                         (values words ws)))))
         (multiple-value-bind (wcount ws-curr) (process-chunk c1 ws-prev)
           (declare (type u8.32 wcount ws-curr))
           (psetf a1 (u64.4+ a1 (u8.32-sad wcount 0x00))
                  ws-prev ws-curr))
         (multiple-value-bind (wcount ws-curr) (process-chunk c2 ws-prev)
           (declare (type u8.32 wcount ws-curr))
           (psetf a2 (u64.4+ a2 (u8.32-sad wcount 0x00))
                  ws-prev ws-curr))
         (multiple-value-bind (wcount ws-curr) (process-chunk c3 ws-prev)
           (declare (type u8.32 wcount ws-curr))
           (psetf a3 (u64.4+ a3 (u8.32-sad wcount 0x00))
                  ws-prev ws-curr))
         (multiple-value-bind (wcount ws-curr) (process-chunk c4 ws-prev)
           (declare (type u8.32 wcount ws-curr))
           (psetf a4 (u64.4+ a4 (u8.32-sad wcount 0x00))
                  ws-prev ws-curr)))
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

(defun count-words-utf8 (sap size ws-prev )
  (count-words-ascii sap size ws-prev))

;; count chars

(defun count-chars-utf8 (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (loop
    with loop-end of-type fixnum = (logandc2 size 255)
    for i of-type fixnum from 0 below loop-end by 256

    with 0x0 of-type u8.32 = (u8.32 #x00)
    with 0x8 of-type u8.32 = (u8.32 #x80)
    with 0xC of-type u8.32 = (u8.32 #xC0)
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

(declaim (inline count-chars-utf8-strict))
(defun count-chars-utf8-strict (sap size)
  (declare (type fixnum size)
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

    with ed-prev-chunk of-type u8.32 = (u8.32 0)

    for c1 = (u8.32-sap-ref sap (+ i 0))
    for c2 = (u8.32-sap-ref sap (+ i 32))
    for c3 = (u8.32-sap-ref sap (+ i 64))
    for c4 = (u8.32-sap-ref sap (+ i 96))

    do
       (macrolet ((validate-and-count (curr prev)
                    `(let* ((curr ,curr) (prev ,prev))
                       (let* (;; valid starts: ascii + valid leads C2-F4
                              (ascii (u8.32= (u8.32-and curr 0x80) 0x0))
                              (vlead (u8.32= (u8.32-sat- (u8.32- curr 194) 50) 0x0))

                              ;; surrogate check: #xED followed by #xA0-#xBF
                              (ed    (u8.32= curr 0xED))
                              ;; shift ED mask right by 1 to align with follow-up byte
                              ;; (Uses the same alignr logic as the word counter)
                              (ed-prev (u8.32-alignr ed (u8.32-permute128 prev ed #x21) 15))
                              (follow (u8.32= (u8.32-sat- (u8.32- curr #xA0) 31) 0x0))
                              (bad-surr (u8.32-and ed-prev follow))

                              ;; combined mask: valid start and not a forbidden follow-up
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
                  (return (values nil nil (the fixnum (+ chars tail))))))))

(defun count-chars-ascii (sap size)
  (declare (ignore sap))
  (values nil nil size))

;; count lines and words

(defun count-lines-and-words-ascii (sap size ws-init-state)
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

(defun count-lines-and-words-utf8 (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (count-lines-and-words-ascii sap size ws-init-state))

;; count lines and chars

(declaim (inline count-lines-and-chars-utf8-strict))
(defun count-lines-and-chars-utf8-strict (sap size)
  (declare (type fixnum size)
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
    with ed-prev of-type u8.32 = (u8.32 0)

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
                    (when (and (or ascii vlead) (not bad))
                      (incf tchars))
                    (setf prev ed)))

         (return (values (the fixnum (+ lines tlines))
                         nil
                         (the fixnum (+ chars tchars)))))))

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

(defun count-lines-and-chars-ascii (sap size)
  (values (count-lines-ascii sap size) nil size))

;; count words and chars

(defun count-words-and-chars-utf8 (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
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
    with 0x20 of-type u8.32 = (u8.32 #x20)

    ;; accumulators
    with wa of-type u64.4 = (u64.4 0)
    with ca of-type u64.4 = (u64.4 0)

    ;; carry state
    with ws-prev of-type u8.32 = (u8.32 ws-init-state)

    ;; chunks
    for c1 = (u8.32-sap-ref sap (+ i 0))
    for c2 = (u8.32-sap-ref sap (+ i 32))
    for c3 = (u8.32-sap-ref sap (+ i 64))
    for c4 = (u8.32-sap-ref sap (+ i 96))

    do
       (macrolet ((process-chunk (curr prev)
                    `(let* ((curr ,curr) (prev ,prev))
                       (let* ((ctrl (u8.32-sat- (u8.32- curr 9) 4))
                              (ws   (u8.32-or (u8.32= ctrl 0x0) (u8.32= curr 0x20)))

                              (ws-sh  (u8.32-alignr ws (u8.32-permute128 prev ws #x21) 15))
                              (wmask (u8.32-andc1 ws ws-sh))

                              (cont  (u8.32= (u8.32-and curr 0xC0) 0x80))
                              (cmask (u8.32-andc1 cont 0xFF)))
                         (values wmask cmask ws)))))

         (multiple-value-bind (wm cm ws) (process-chunk c1 ws-prev)
           (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                  ca (u64.4+ ca (u8.32-sad cm 0x0))
                  ws-prev ws))
         (multiple-value-bind (wm cm ws) (process-chunk c2 ws-prev)
           (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                  ca (u64.4+ ca (u8.32-sad cm 0x0))
                  ws-prev ws))
         (multiple-value-bind (wm cm ws) (process-chunk c3 ws-prev)
           (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                  ca (u64.4+ ca (u8.32-sad cm 0x0))
                  ws-prev ws))
         (multiple-value-bind (wm cm ws) (process-chunk c4 ws-prev)
           (psetf wa (u64.4+ wa (u8.32-sad wm 0x0))
                  ca (u64.4+ ca (u8.32-sad cm 0x0))
                  ws-prev ws)))
    finally
       (return
         (loop for j from loop-end below size
               with words  of-type fixnum  = (sum-lanes wa)
               with chars  of-type fixnum  = (sum-lanes ca)
               with twords of-type fixnum  = 0
               with tchars of-type fixnum  = 0
               with prev   of-type boolean = (logbitp 31 (u8.32-movemask ws-prev))

               for byte of-type fixnum     = (sb-sys:sap-ref-8 sap j)
               for curr of-type boolean    = (or (= byte 32) (<= 9 byte 13))
               do
                  (when (and (not curr) prev) (incf twords))
                  (when (/= (logand byte #xC0) #x80) (incf tchars))
                  (setf prev curr)
               finally
                  (return (values nil
                                  (the fixnum (+ words twords))
                                  (the fixnum (+ chars tchars))))))))

(declaim (inline count-words-and-chars-utf8-strict))
(defun count-words-and-chars-utf8-strict (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
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
    with wa  of-type u64.4 = (u64.4 0)
    with ca  of-type u64.4 = (u64.4 0)

    ;; carry
    with ws-prev of-type u8.32 = (u8.32 ws-init-state)
    with ed-prev of-type u8.32 = (u8.32 0)

    ;; chunks
    for c1 = (u8.32-sap-ref sap (+ i 0))
    for c2 = (u8.32-sap-ref sap (+ i 32))
    for c3 = (u8.32-sap-ref sap (+ i 64))
    for c4 = (u8.32-sap-ref sap (+ i 96))

    do
       (macrolet ((process-chunk (chunk prev-ws prev-ed)
                    `(let* ((chunk ,chunk) (prev-ws ,prev-ws) (prev-ed ,prev-ed))
                       (let* (;; word crossing detection
                              (ctrl  (u8.32-sat- (u8.32- chunk 9) 4))
                              (ws    (u8.32-or (u8.32= ctrl 0x0) (u8.32= chunk 0x20)))
                              (ws-sh (u8.32-alignr ws (u8.32-permute128 prev-ws ws #x21) 15))
                              (wmask (u8.32-andc1 ws ws-sh))

                              ;; strict utf8 validation (range + surrogate check)
                              (ascii (u8.32= (u8.32-and chunk 0x80) 0x0))
                              (vlead (u8.32= (u8.32-sat- (u8.32- chunk 194) 50) 0x0))
                              (ed    (u8.32= chunk 0xED))
                              (ed-sh (u8.32-alignr ed (u8.32-permute128 prev-ed ed #x21) 15))
                              (foll  (u8.32= (u8.32-sat- (u8.32- chunk #xA0) 31) 0x0))
                              (bads  (u8.32-and ed-sh foll))
                              (cmask (u8.32-andc1 bads (u8.32-or ascii vlead))))
                         (values wmask cmask ws ed)))))

         (multiple-value-bind (wm cm ws ed) (process-chunk c1 ws-prev ed-prev)
           (setf wa (u64.4+ wa (u8.32-sad wm 0x0))
                 ca (u64.4+ ca (u8.32-sad cm 0x0))
                 ws-prev ws ed-prev ed))
         (multiple-value-bind (wm cm ws ed) (process-chunk c2 ws-prev ed-prev)
           (setf wa (u64.4+ wa (u8.32-sad wm 0x0))
                 ca (u64.4+ ca (u8.32-sad cm 0x0))
                 ws-prev ws ed-prev ed))
         (multiple-value-bind (wm cm ws ed) (process-chunk c3 ws-prev ed-prev)
           (setf wa (u64.4+ wa (u8.32-sad wm 0x0))
                 ca (u64.4+ ca (u8.32-sad cm 0x0))
                 ws-prev ws ed-prev ed))
         (multiple-value-bind (wm cm ws ed) (process-chunk c4 ws-prev ed-prev)
           (setf wa (u64.4+ wa (u8.32-sad wm 0x0))
                 ca (u64.4+ ca (u8.32-sad cm 0x0))
                 ws-prev ws ed-prev ed)))
    finally
       (let* ((words (sum-lanes wa))
              (chars (sum-lanes ca))
              (prev-ws (logbitp 31 (u8.32-movemask ws-prev)))
              (prev-ed (logbitp 31 (u8.32-movemask ed-prev)))
              (twords 0) (tchars 0))
         (declare (type fixnum words chars twords tchars))

         (loop for j from loop-end below size
               do (let* ((byte (sb-sys:sap-ref-8 sap j))
                         (curr-ws (or (= byte 32) (<= 9 byte 13)))
                         (ascii   (<= 0 byte 127))
                         (vlead   (<= 194 byte 244))
                         (bad     (and prev-ed (<= #xA0 byte #xBF))))
                    (when (and (not curr-ws) prev-ws) (incf twords))
                    (when (and (or ascii vlead) (not bad)) (incf tchars))
                    (setf prev-ws curr-ws prev-ed (= byte #xED))))

         (return (values nil
                         (the fixnum (+ words twords))
                         (the fixnum (+ chars tchars)))))))

(defun count-words-and-chars-ascii (sap size ws-init-state)
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (optimize (speed 3) (safety 0)))
  (multiple-value-bind (_ words) (count-words-ascii sap size ws-init-state)
    (declare (ignore _))
    (values nil words size)))


;; count lines, words and chars

(declaim (inline count-lines-words-and-chars-utf8-strict))
(defun count-lines-words-and-chars-utf8-strict (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
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
    with ed-prev of-type u8.32 = (u8.32 #x00)

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

(defun count-lines-words-and-chars-utf8 (sap size ws-init-state)
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
                              (the fixnum (+ chars tchars))))))))

(defun count-lines-words-and-chars-ascii (sap size ws-init-state)
  (declare (type sb-sys:system-area-pointer sap)
           (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (optimize (speed 3) (safety 0)))
  (multiple-value-bind (lines words) (count-lines-and-words-ascii sap size ws-init-state)
    (values lines words size)))

;;; kernels-avx2.cl ends here
