;;; tools/bench-threshold.lisp
;;;
;;; Measures the single-threaded (linear) vs multi-threaded (MT) execution
;;; across various file sizes to determine the break-even threshold where
;;; parallel processing outweighs thread creation and synchronization costs.

(in-package :wc)

(defun run-threshold-benchmark (base-file)
  (format t "~%========================================================================================================================~%")
  (format t " Benchmarking Linear vs MT Across File Sizes (AVX-512, 8 threads, 1 MB chunks)~%")
  (format t " Base file: ~a~%" base-file)
  (format t "========================================================================================================================~%")
  (format t " ~9a | ~22a | ~22a | ~22a | ~14a~%"
          "Size" "Linear (1 thread)" "MT Warm (pool ready)" "MT Cold (spawn pool)" "Speedup (Warm)")
  (format t "------------------------------------------------------------------------------------------------------------------------~%")

  (let* ((nthreads (min 8 (ncpus)))
         (chunk-size +default-chunk-size+)
         (sizes-mb '(0.25 0.5 1.0 2.0 4.0 6.0 8.0 12.0 16.0 24.0 32.0 64.0)))

    ;; Pre-ensure worker pool exists for warm testing
    (ensure-worker-pool nthreads chunk-size)

    (dolist (sz sizes-mb)
      (let* ((target-bytes (round (* sz 1024 1024)))
             (tmp-path (format nil "/tmp/wc_bench_thresh_~a.tmp" sz)))
        (unwind-protect
             (progn
               ;; Create truncated temporary slice from base file
               (with-open-file (in base-file :direction :input :element-type '(unsigned-byte 8))
                 (with-open-file (out tmp-path :direction :output :if-exists :supersede
                                               :element-type '(unsigned-byte 8))
                   (let ((buf (make-array (min target-bytes (* 1024 1024)) :element-type '(unsigned-byte 8)))
                         (rem target-bytes))
                     (loop while (> rem 0) do
                       (let* ((to-read (min rem (length buf)))
                              (n (read-sequence buf in :end to-read)))
                         (when (zerop n) (return))
                         (write-sequence buf out :end n)
                         (decf rem n))))))

               (let* ((fd (sb-posix:open tmp-path sb-posix:o-rdonly))
                      (size (sb-posix:lseek fd 0 sb-posix:seek-end))
                      (iters (max 5 (min 50 (floor 50000000 (max 1 size))))))
                 (unwind-protect
                      (progn
                        ;; Warm-up run
                        (sb-posix:lseek fd 0 sb-posix:seek-set)
                        (process-fd-linear fd 7 :chars :avx512 chunk-size)

                        ;; 1. Measure Linear
                        (let ((t0 (get-internal-real-time)))
                          (dotimes (i iters)
                            (sb-posix:lseek fd 0 sb-posix:seek-set)
                            (process-fd-linear fd 7 :chars :avx512 chunk-size))
                          (let ((dt-lin (/ (- (get-internal-real-time) t0) (* iters 1.0 internal-time-units-per-second))))

                            ;; 2. Measure MT Warm
                            (let ((t1 (get-internal-real-time)))
                              (dotimes (i iters)
                                (process-fd-mt fd size nthreads 7 :chars :avx512 chunk-size))
                              (let ((dt-mt-warm (/ (- (get-internal-real-time) t1) (* iters 1.0 internal-time-units-per-second))))

                                ;; 3. Measure MT Cold (pool torn down and rebuilt per run)
                                (let ((cold-iters (min 5 iters))
                                      (t2 (get-internal-real-time)))
                                  (dotimes (i cold-iters)
                                    (shutdown-worker-pool)
                                    (process-fd-mt fd size nthreads 7 :chars :avx512 chunk-size))
                                  (let ((dt-mt-cold (/ (- (get-internal-real-time) t2) (* cold-iters 1.0 internal-time-units-per-second))))
                                    (format t " ~6,2f MB | ~8,6f s (~5,1f GB/s) | ~8,6f s (~5,1f GB/s) | ~8,6f s (~5,1f GB/s) | ~5,2fx~%"
                                            sz
                                            dt-lin (/ (/ size 1e9) (max 1e-9 dt-lin))
                                            dt-mt-warm (/ (/ size 1e9) (max 1e-9 dt-mt-warm))
                                            dt-mt-cold (/ (/ size 1e9) (max 1e-9 dt-mt-cold))
                                            (/ dt-lin (max 1e-9 dt-mt-warm))))))))))
                   (sb-posix:close fd))))
          (when (probe-file tmp-path)
            (delete-file tmp-path)))))

    (format t "========================================================================================================================~%~%")))
