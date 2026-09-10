;;;; cl-bench under the WebAssembly port (Sprint 12): compiles the
;;;; benchmark files with the running Lisp, runs each benchmark a scaled
;;;; number of times and prints one line per benchmark that the
;;;; comparison script (cl-bench-compare.sh) reads:
;;;;   RESULT <name> <runs> <real-seconds>  or  RESULT <name> SKIP <reason>
;;;;
;;;; usage (any SBCL, so the host can produce a reference too):
;;;;   sbcl --script tests/wasm/bench/cl-bench-driver.lisp <cl-bench-dir> <fasl-dir> <scale> [names...]
;;;; SCALE divides every benchmark's run count (at least one run); a
;;;; benchmark whose runs take longer than CL_BENCH_TIMEOUT seconds
;;;; (default 900) is given up and reported as skipped;
;;;; NAMES restrict the run to those benchmarks (the names of tests.lisp,
;;;; case-insensitive), or the groups given as :GABRIEL etc.
;;;;
;;;; cl-bench depends on ASDF and trivial-garbage for two things only
;;;; (the source directory and a full collection); stand-ins are defined
;;;; here so that the files load without either. Benchmarks that compile
;;;; or load files, or read the misc/ inputs, are left to the names given.

(defpackage #:trivial-garbage
  (:use #:cl)
  (:export #:gc))
(in-package #:trivial-garbage)
(defun gc (&key full)
  (declare (ignorable full))
  #+sbcl (sb-ext:gc :full t)
  #-sbcl nil)

(in-package #:cl-user)

(defvar *args* (rest #+sbcl sb-ext:*posix-argv* #-sbcl nil))
(when (and *args* (string= (first *args*) "--script")) (setf *args* (cddr *args*)))
(defvar *bench-dir* (let ((d (or (first *args*) "/home/user/tools/cl-bench/")))
                      (if (char= (char d (1- (length d))) #\/) d (concatenate 'string d "/"))))
(defvar *fasl-dir* (let ((d (or (second *args*) "/tmp/cl-bench-fasl/")))
                     (if (char= (char d (1- (length d))) #\/) d (concatenate 'string d "/"))))
(defvar *scale* (let ((s (third *args*))) (if s (parse-integer s) 1)))
(defvar *names* (mapcar #'string-upcase (cdddr *args*)))
;; seconds a benchmark's runs may take before it is given up
(defvar *timeout* (let ((s (sb-ext:posix-getenv "CL_BENCH_TIMEOUT"))) (if s (parse-integer s) 900)))

(ensure-directories-exist *fasl-dir*)

(load (merge-pathnames "package.lisp" *bench-dir*))
(in-package #:cl-bench)
(defun bench-gc () (trivial-garbage:gc :full t))
(defparameter *root-dir* cl-user::*bench-dir*)
(defparameter *misc-dir* (merge-pathnames "misc/" *root-dir*))
(defparameter *output-dir* (merge-pathnames "output/" cl-user::*fasl-dir*))
(ensure-directories-exist *output-dir*)
(in-package #:cl-user)

(defun bench-load (name)
  "Compile files/NAME.lisp (or NAME.lisp at the root) into the fasl
directory and load the fasl; prints the compile time."
  (let* ((source (or (probe-file (merge-pathnames (format nil "files/~A.lisp" name) *bench-dir*))
                     (merge-pathnames (format nil "~A.lisp" name) *bench-dir*)))
         (fasl (merge-pathnames (format nil "~A.fasl" name) *fasl-dir*))
         (start (get-internal-real-time)))
    (let ((*compile-verbose* nil) (*compile-print* nil))
      (handler-bind ((warning #'muffle-warning))
        (compile-file source :output-file fasl)))
    (format t "~&COMPILE ~A ~,3F~%" name
            (/ (- (get-internal-real-time) start) internal-time-units-per-second))
    (let ((*load-verbose* nil))
      (load fasl))))

(dolist (f '("support" "arrays" "bignum" "boehm-gc" "clos" "crc40" "deflate"
             "gabriel" "hash" "math" "misc" "ratios" "richards" "tests"))
  (bench-load f))

(defun selected-p (b)
  (or (null *names*)
      (member (string-upcase (symbol-name (cl-bench::benchmark-name b))) *names* :test #'string=)
      (member (string-upcase (symbol-name (cl-bench::benchmark-group b))) *names* :test #'string=)))

(dolist (b (reverse cl-bench::*benchmarks*))
  (when (selected-p b)
    (let* ((name (string-downcase (symbol-name (cl-bench::benchmark-name b))))
           (runs (max 1 (round (cl-bench::benchmark-runs b) *scale*)))
           (setup (slot-value b 'cl-bench::setup))
           (function (cl-bench::benchmark-function b)))
      (handler-case
          (if (some (lambda (feature) (member feature *features*))
                    (cl-bench::benchmark-disabled-for b))
              (format t "~&RESULT ~A SKIP disabled for this implementation~%" name)
              (progn
                (cl-bench::bench-gc)
                (when setup (funcall setup))
                (let ((start (get-internal-real-time)))
                  (#+sbcl sb-ext:with-timeout #+sbcl *timeout* #-sbcl progn
                    (dotimes (i runs) (funcall function)))
                  (format t "~&RESULT ~A ~D ~,3F~%" name runs
                          (/ (- (get-internal-real-time) start) internal-time-units-per-second)))))
        #+sbcl
        (sb-ext:timeout ()
          (format t "~&RESULT ~A SKIP timeout after ~D seconds~%" name *timeout*))
        (error (c)
          (format t "~&RESULT ~A SKIP ~A~%" name
                  (substitute #\space #\newline (princ-to-string c)))))
      (finish-output))))
(format t "~&DONE~%")
