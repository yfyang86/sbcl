;;;; This file contains the WebAssembly-specific runtime stuff.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

(defun machine-type ()
  "Return a string describing the type of the local machine."
  "WASM32")

;;; A "context" on this target is the register file the runtime saved
;;; when a trap or an interrupt entered it (doc/wasm-port/02-design.md,
;;; 2.4): the same word slots the compiled code uses. The return address
;;; register holds the descriptor of the return point of the current
;;; call, not a machine address.
(defun return-machine-address (scp)
  (context-register scp ra-offset))

;;; CONTEXT-FLOAT-REGISTER
(define-alien-routine ("os_context_float_register_addr" context-float-register-addr)
  (* unsigned) (context (* os-context-t)) (index int))

(defun context-float-register (context index format &optional integer)
  (declare (ignore integer))
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (sap-ref-single sap 0))
      (double-float
       (sap-ref-double sap 0))
      (complex-single-float
       (complex (sap-ref-single sap 0)
                (sap-ref-single sap 4)))
      (complex-double-float
       (complex (sap-ref-double sap 0)
                (sap-ref-double sap 8))))))

(defun %set-context-float-register (context index format value)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (setf (sap-ref-single sap 0) value))
      (double-float
       (setf (sap-ref-double sap 0) value))
      (complex-single-float
       (locally
           (declare (type (complex single-float) value))
         (setf (sap-ref-single sap 0) (realpart value)
               (sap-ref-single sap 4) (imagpart value))))
      (complex-double-float
       (locally
           (declare (type (complex double-float) value))
         (setf (sap-ref-double sap 0) (realpart value)
               (sap-ref-double sap 8) (imagpart value)))))))

;;; INTERNAL-ERROR-ARGS

;;; Compiled code reports an internal error by storing one SC+OFFSET
;;; word per argument into the thread's error-argument area and calling
;;; the runtime import INTERNAL_ERROR with (kind code nargs); the runtime
;;; records the three words in front of the arguments and hands a
;;; pointer to that block to the Lisp handler through the context.
(define-alien-routine ("os_context_error_args_addr" context-error-args-addr)
  (* unsigned) (context (* os-context-t)))

(defun internal-error-args (context)
  (declare (type (alien (* os-context-t)) context))
  (let* ((sap (alien-sap (context-error-args-addr context)))
         (kind (sap-ref-32 sap 0))
         (code (sap-ref-32 sap 4))
         (nargs (sap-ref-32 sap 8)))
    (if (= kind invalid-arg-count-trap)
        (values #.(error-number-or-lose 'invalid-arg-count-error)
                '(#.arg-count-sc))
        (values code
                (loop for i below nargs
                      collect (sap-ref-32 sap (+ 12 (* i 4))))))))

;;; CONTEXT-CALL-FUNCTION

;;; Undo the effects of XEP-ALLOCATE-FRAME and point PC to FUNCTION.
;;; Redirecting a trapped function needs the runtime's help on this
;;; target (there is no PC to rewrite); it belongs to the runtime port.
(defun context-call-function (context function &optional arg-count)
  (declare (ignore context function arg-count))
  (style-warn "Unimplemented."))
