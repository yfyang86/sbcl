;;;; A subset of pure tests for the browser host's Playwright suite
;;;; (Sprint 14): language checks with no I/O, run in the worker against
;;;; the same core the suites run against under Wasmtime. The page loads
;;;; this file into the in-memory file system (?load=); the suite
;;;; (tests/wasm/web/repl.spec.mjs) loads it in Lisp and asks for the
;;;; summary with PURE-CHECKS-REPORT.

(defpackage #:pure-checks
  (:use #:cl)
  (:export #:run #:report))
(in-package #:pure-checks)

(defvar *failures* 0)
(defvar *checks* 0)

(defmacro with-check (description expected-values form)
  `(let ((result (multiple-value-list ,form)))
     (incf *checks*)
     (if (equalp result ',expected-values)
         (format t "ok   ~A~%" ,description)
         (progn (incf *failures*)
                (format t "FAIL ~A: got ~S, wanted ~S~%"
                        ,description result ',expected-values)))))

(defun run ()
  (with-check "fixnum arithmetic" (7) (+ 3 4))
  (with-check "bignum arithmetic" (3000000000) (* 1000000 3000))
  (with-check "ratio" (3/2) (+ 1 1/2))
  (with-check "single-float" (1.5) (+ 1.0 0.5))
  (with-check "double-float" (2.5d0) (+ 2.0d0 0.5d0))
  (with-check "complex" (#c(1 2)) (+ #c(1 0) #c(0 2)))
  (with-check "string" ("dlrow") (reverse "world"))
  (with-check "symbol char" (#\A) (char-upcase #\a))
  (with-check "list" ((1 2 3 4)) (append '(1 2) '(3 4)))
  (with-check "assoc" (2) (cdr (assoc 1 '((1 . 2) (3 . 4)))))
  (with-check "vector" (9) (aref (make-array 5 :initial-element 9) 3))
  (with-check "hash table" (42 t) (let ((h (make-hash-table)))
                                  (setf (gethash 'k h) 42)
                                  (gethash 'k h)))
  (with-check "clos" (5) (progn
                           (defclass pc-point () ((x :initarg :x :reader pc-x)))
                           (pc-x (make-instance 'pc-point :x 5))))
  (with-check "closure" (9) (let ((n 4)) (funcall (lambda (m) (+ m n)) 5)))
  (with-check "recursion" (120) (labels ((fact (n) (if (zerop n) 1 (* n (fact (1- n))))))
                                 (fact 5)))
  (with-check "higher-order" ((1 4 9)) (mapcar (lambda (x) (* x x)) '(1 2 3)))
  (with-check "string formatting" ("42") (format nil "~D" 42))
  (with-check "multiple values" (1 2 3) (values 1 2 3))
  (with-check "catch and throw" (:caught) (catch 'tag
                                            (throw 'tag :caught)))
  (with-check "unwind-protect" (1) (let ((n 0))
                                     (handler-case
                                         (unwind-protect (error "x")
                                           (incf n))
                                       (error () nil))
                                     n))
  (with-check "condition handling" (:handled) (handler-case (error "boom")
                                               (error () :handled)))
  (with-check "compile at run time" (49) (funcall (compile nil '(lambda (x) (* x x))) 7))
  (values))

(defun report ()
  (format t "PURE-CHECKS: ~D/~D~%" (- *checks* *failures*) *checks*)
  (values *failures* *checks*))
