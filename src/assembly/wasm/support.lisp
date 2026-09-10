;;;; the machine-specific support routines needed by the assembler
;;;; routine definer, for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-VM")

;;; An assembly routine is an ordinary Wasm function in the core module;
;;; calling one is a direct CALL through a fixup that resolves to its
;;; function index.
;;; Every routine has the Lisp function type () -> (i32); the result is
;;; meaningless for a routine that returns to its caller (:RAW) and is
;;; dropped, and a routine that never returns (:NONE) still has to be
;;; called with the same type.
(defun generate-call-sequence (name style vop options)
  (declare (ignore vop options))
  (ecase style
    ((:raw :none)
     (values
      `((emit-lisp-call-args)
        (inst call (make-fixup ',name :assembly-routine))
        (inst drop))
      `()))))

(defun generate-return-sequence (style)
  (ecase style
    (:raw `((inst i32.const 0)
            (inst return)))
    (:none)))
