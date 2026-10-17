;; kernels-generic.cl
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

;; Portable, non-SIMD baseline for the same word/line/char counters
;; kernels-avx2.cl and kernels-avx512.cl provide. Every name here has a
;; "-GENERIC" suffix. avx2 names are unsuffixed, are the "AVX2" family;
;; see WC-TASKS.CL's KERNEL-CALL) so all three implementations can be
;; compiled into the same image and picked at runtime via
;; --implementation, instead of one silently redefining another's names.
;;
;; This file needs neither SB-SIMD nor an AVX-512-capable SBCL build, so
;; unlike kernels-avx512.cl it is always compiled. These generic kernels
;; are pure SWAR and use portable LOGCOUNT rather than a POPCNT VOP so they
;; run even without modern instruction sets (though note the full default
;; wordcount binary also includes kernels-avx2.cl).
;;
;; The combined counters (LINES-AND-WORDS, WORDS-AND-CHARS, ...) still
;; just call the single-purpose ones below rather than fusing loops --
;; unlike kernels-avx2.cl/kernels-avx512.cl, a fused pass here would
;; only save the SAP-REF-64 load itself (one extra 8-byte read per
;; chunk is cheap next to the bit-twiddling), and keeping each
;; statistic in its own small loop keeps this file easy to check by
;; eye against kernels-avx2.cl's algorithms.
;;
;; This file is ported from another little experimental project by me.
;; In that one I use macros to generate fused and completely branchless
;; loops at compile time:
;;
;; (macrolet ((genloop (clines cwords cchars wslut nllut)
;;                    (declare (ignorable wslut nllut))
;;                    `(loop
;;                       with lines of-type fixnum = 0
;;                       with words of-type fixnum = 0
;;                       with chars of-type fixnum = (if ,cchars (file-length stream) 0)
;;                       with prev of-type (unsigned-byte 8) = 1
;;                       for bytes-read of-type fixnum = (read-sequence buffer stream)
;;                       while (> bytes-read 0)
;;                       do
;;                          (loop for i of-type fixnum from 0 below bytes-read
;;                                for c of-type (unsigned-byte 8) = (aref buffer i)
;;                                do
;;                               ,@(when clines `((incf lines (aref nllut c))))
;;                               ,@(when cwords
;;                                   `((let ((curr (aref wslut c)))
;;                                       (declare (type (unsigned-byte 8) curr))
;;                                       (incf words (logandc2 prev curr))
;;                                       (setf prev curr)))))
;;                       finally (return (values lines words chars)))))
;;          .......
;;
;; but in this project, focus was on simd, so I haven't merged them into
;; one. Intead the generic path in this one follows the simd code rather
;; than the macro approach. But I do have ambition to one day test if I
;; can also generate simd kernels with macros too.
;;
;;; Code:
#-sbcl
(error "This file requires SBCL compiler.")

(declaim (optimize (speed 3) (safety 0)))

(in-package :wc)

;; All 15 dispatched names declared inline up front, the same way
;; kernels-avx2.cl does it for its own (unsuffixed) names -- a
;; per-function declaim here would still work for the ones that
;; precede their own defun, but omitting even one of the "thin
;; passthrough" wrappers (COUNT-LINES-ASCII-GENERIC and friends) below
;; costs a SAP-boxing full call at every task instead of an inlined
;; one; one blanket declaim can't miss any of them.
(declaim (inline count-lines-generic
                 count-lines-words-and-chars-utf8-generic
                 count-lines-words-and-chars-ascii-generic
                 count-lines-words-and-chars-utf8-strict-generic
                 count-lines-utf8-generic count-words-utf8-generic
                 count-chars-utf8-generic count-chars-utf8-strict-generic
                 count-lines-ascii-generic count-words-ascii-generic count-chars-ascii-generic
                 count-lines-and-words-utf8-generic count-lines-and-words-ascii-generic
                 count-words-and-chars-utf8-generic count-words-and-chars-utf8-strict-generic
                 count-lines-and-chars-utf8-generic count-lines-and-chars-utf8-strict-generic
                 count-words-and-chars-ascii-generic count-lines-and-chars-ascii-generic))

(declaim (inline %generic-ws-p))
(defun %generic-ws-p (byte)
  (declare (type (unsigned-byte 8) byte) (optimize (speed 3) (safety 0)))
  (or (= byte 32) (<= 9 byte 13)))

;;; SWAR helpers each one isolates bit 7 of every byte lane of an
;;; 8-byte CHUNK where some per-byte predicate holds (or, for the
;;; UTF8-COUNT-FAST/STRICT pair, returns an already-summed count). See
;;; the file commentary above for why masks are built byte-by-byte
;;; (DO-CHUNK-BYTES) rather than with the classic subtraction trick.

(declaim (inline swar-byte))
;; Byte K (0 = least significant) of 8-byte CHUNK.
(defun swar-byte (chunk k)
  (declare (type (unsigned-byte 64) chunk) (type (integer 0 7) k)
           (optimize (speed 3) (safety 0)))
  (ldb (byte 8 (* k 8)) chunk))


;; Bind BYTE-VAR to each of CHUNK's 8 bytes in turn, accumulating bit 7
;; of that lane into MASK-VAR (already bound) whenever BODY is true.
(defmacro do-chunk-bytes ((byte-var chunk mask-var) &body body)
  (let ((k (gensym "K")))
    `(dotimes (,k 8 ,mask-var)
       (let ((,byte-var (swar-byte ,chunk ,k)))
         (when (progn ,@body)
           (setf ,mask-var (logior ,mask-var (ash #x80 (* ,k 8)))))))))

(declaim (inline swar-newline-mask))
;; Bit 7 of each byte lane set iff that byte is #\\Newline (10).
(defun swar-newline-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (= byte 10))))

(declaim (inline swar-ws-mask))
;; Bit 7 of each byte lane set iff that byte is ASCII whitespace
;; (space, or in [9,13]).
(defun swar-ws-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (%generic-ws-p byte))))

(declaim (inline swar-word-starts))
;; Count of word-start transitions (whitespace -> non-whitespace)
;; within WS-MASK (see SWAR-WS-MASK). PREV-HIGH-BIT carries the previous
;; chunk's last byte's whitespace bit (0 or #x80) into byte 0's position.
(defun swar-word-starts (ws-mask prev-high-bit)
  (declare (type (unsigned-byte 64) ws-mask) (type (unsigned-byte 8) prev-high-bit)
           (optimize (speed 3) (safety 0)))
  (let* ((shifted (logior (ldb (byte 64 0) (ash ws-mask 8)) prev-high-bit))
         (transitions (logand shifted (lognot ws-mask) #x8080808080808080)))
    (declare (type (unsigned-byte 64) shifted transitions))
    (the fixnum (logcount transitions))))

(declaim (inline swar-chunk-carry))
;; Extract byte 7's high bit from MASK (0 or #x80), to seed the next
;; chunk's carry.
(defun swar-chunk-carry (mask)
  (declare (type (unsigned-byte 64) mask) (optimize (speed 3) (safety 0)))
  (ldb (byte 8 0) (ash mask -56)))

(declaim (inline swar-utf8-count-fast))
;; Extract byte 7's high bit from MASK (0 or #x80), to seed the next
;; chunk's carry.
(defun swar-utf8-count-fast (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0)))
  (let* ((shifted (ldb (byte 64 0) (ash chunk 1)))
         (cont-mask (logand chunk (lognot shifted) #x8080808080808080)))
    (declare (type (unsigned-byte 64) shifted cont-mask))
    (the fixnum (- 8 (logcount cont-mask)))))

(declaim (inline swar-utf8-valid-lead-mask))
;; Bit 7 of each byte lane set iff that byte is ASCII (<=0x7F) or a
;; valid multi-byte UTF-8 lead byte (0xC2-0xF4) -- the surrogate-half
;; exclusion is handled separately by SWAR-BAD-SURROGATE-MASK below,
;; since it needs the previous chunk's carry.
(defun swar-utf8-valid-lead-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (or (<= byte #x7F) (<= #xC2 byte #xF4)))))

(declaim (inline swar-ed-mask))
;; Bit 7 of each byte lane set iff that byte is 0xED (a UTF-8 lead byte
;; that may introduce an illegal surrogate-half encoding).
(defun swar-ed-mask (chunk)
  (declare (type (unsigned-byte 64) chunk) (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let ((mask 0))
    (declare (type (unsigned-byte 64) mask))
    (do-chunk-bytes (byte chunk mask) (= byte #xED))))

(declaim (inline swar-bad-surrogate-mask))
;; Bit 7 of each byte lane set iff that byte is an A0-BF follow-up to
;; an immediately preceding 0xED lead (the illegal UTF-8 encoding of a
;; surrogate half) -- PREV-ED-HIGH-BIT carries the previous chunk's last
;; byte's \"was 0xED\" bit (0 or #x80) the same way SWAR-WORD-STARTS'
;; PREV-HIGH-BIT does. Second value is the new carry for the next chunk.
(defun swar-bad-surrogate-mask (chunk prev-ed-high-bit)
  (declare (type (unsigned-byte 64) chunk)
           (type (unsigned-byte 8) prev-ed-high-bit)
           (optimize (speed 3) (safety 0))
           (sb-ext:muffle-conditions sb-ext:compiler-note))
  (let* ((ed-mask (swar-ed-mask chunk))
         (follow-mask 0)
         (ed-shifted (logior (ldb (byte 64 0) (ash ed-mask 8)) prev-ed-high-bit)))
    (declare (type (unsigned-byte 64) follow-mask ed-shifted))
    (setf follow-mask (do-chunk-bytes (byte chunk follow-mask) (<= #xA0 byte #xBF)))
    (values (logand ed-shifted follow-mask) (swar-chunk-carry ed-mask))))

;; count lines: only \n = LF = 10 (0xA) matters, ascii or utf8 alike.
(defun count-lines-generic (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 7))
        (lines 0))
    (declare (type fixnum loop-end lines))
    (loop for i of-type fixnum from 0 below loop-end by 8
          do (incf lines (logcount (swar-newline-mask (sb-sys:sap-ref-64 sap i)))))
    (loop for j of-type fixnum from loop-end below size
          when (= (sb-sys:sap-ref-8 sap j) 10) do (incf lines))
    (values lines nil nil)))

(defun count-lines-utf8-generic (sap size) (count-lines-generic sap size))
(defun count-lines-ascii-generic (sap size) (count-lines-generic sap size))

;; count words -- a word starts where a whitespace byte (or the
;; incoming carry, for the very first byte) is followed by a
;; non-whitespace byte; ascii and utf8 alike, since none of the
;; whitespace bytes ever appear inside a multi-byte utf8 sequence.

(defun count-words-ascii-generic (sap size ws-init-state)
  (declare (type fixnum size)
           (type (unsigned-byte 8) ws-init-state)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 7))
        (words 0)
        (prev-hi (if (zerop ws-init-state) 0 #x80)))
    (declare (type fixnum loop-end words) (type (unsigned-byte 8) prev-hi))
    (loop for i of-type fixnum from 0 below loop-end by 8
          for ws-mask of-type (unsigned-byte 64) = (swar-ws-mask (sb-sys:sap-ref-64 sap i))
          do (incf words (swar-word-starts ws-mask prev-hi))
             (setf prev-hi (swar-chunk-carry ws-mask)))
    (values nil
            (the fixnum
                 (loop for j of-type fixnum from loop-end below size
                       with prev of-type boolean = (not (zerop prev-hi))
                       for curr of-type boolean = (%generic-ws-p (sb-sys:sap-ref-8 sap j))
                       do
                          (and prev (not curr) (incf words))
                          (setf prev curr)
                       finally (return words)))
            nil)))

(defun count-words-utf8-generic (sap size ws-init-state)
  (count-words-ascii-generic sap size ws-init-state))

;; count chars ascii: one byte is one char, no scan needed.
(defun count-chars-ascii-generic (sap size)
  (declare (ignore sap)
           (type fixnum size)
           (optimize (speed 3) (safety 0)))
  (values nil nil size))

;; count chars lenient utf8: a byte starts a character unless it's
;; a continuation byte (10xxxxxx, i.e. (byte & 0xC0) == 0x80).
(defun count-chars-utf8-generic (sap size)
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

;; count chars strict utf8: a byte starts a character iff it's
;; ascii or a valid multi-byte lead (C2-F4), unless it's the A0-BF
;; continuation of an 0xED lead (the encoding of an illegal surrogate
;; half)
(defun count-chars-utf8-strict-generic (sap size)
  (declare (type fixnum size)
           (type sb-sys:system-area-pointer sap)
           (optimize (speed 3) (safety 0)))
  (let ((loop-end (logandc2 size 7))
        (chars 0)
        (prev-ed-hi 0))
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


;; combined counters
(defun count-lines-and-words-ascii-generic (sap size ws-init-state)
  (values (nth-value 0 (count-lines-generic sap size))
          (nth-value 1 (count-words-ascii-generic sap size ws-init-state))
          nil))

(defun count-lines-and-words-utf8-generic (sap size ws-init-state)
  (count-lines-and-words-ascii-generic sap size ws-init-state))

(defun count-lines-and-chars-ascii-generic (sap size)
  (values (nth-value 0 (count-lines-generic sap size)) nil size))

(defun count-lines-and-chars-utf8-generic (sap size)
  (values (nth-value 0 (count-lines-generic sap size))
          nil
          (nth-value 2 (count-chars-utf8-generic sap size))))

(defun count-lines-and-chars-utf8-strict-generic (sap size)
  (values (nth-value 0 (count-lines-generic sap size))
          nil
          (nth-value 2 (count-chars-utf8-strict-generic sap size))))

(defun count-words-and-chars-ascii-generic (sap size ws-init-state)
  (values nil
          (nth-value 1 (count-words-ascii-generic sap size ws-init-state))
          size))

(defun count-words-and-chars-utf8-generic (sap size ws-init-state)
  (values nil
          (nth-value 1 (count-words-ascii-generic sap size ws-init-state))
          (nth-value 2 (count-chars-utf8-generic sap size))))

(defun count-words-and-chars-utf8-strict-generic (sap size ws-init-state)
  (values nil
          (nth-value 1 (count-words-ascii-generic sap size ws-init-state))
          (nth-value 2 (count-chars-utf8-strict-generic sap size))))

(defun count-lines-words-and-chars-ascii-generic (sap size ws-init-state)
  (values (nth-value 0 (count-lines-generic sap size))
          (nth-value 1 (count-words-ascii-generic sap size ws-init-state))
          size))

(defun count-lines-words-and-chars-utf8-generic (sap size ws-init-state)
  (values (nth-value 0 (count-lines-generic sap size))
          (nth-value 1 (count-words-ascii-generic sap size ws-init-state))
          (nth-value 2 (count-chars-utf8-generic sap size))))

(defun count-lines-words-and-chars-utf8-strict-generic (sap size ws-init-state)
  (values (nth-value 0 (count-lines-generic sap size))
          (nth-value 1 (count-words-ascii-generic sap size ws-init-state))
          (nth-value 2 (count-chars-utf8-strict-generic sap size))))

;;; kernels-generic.cl ends here
