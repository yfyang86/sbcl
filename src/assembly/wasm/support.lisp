;;;; the machine-specific support routines needed by the assembler
;;;; routine definer, for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-VM")

;;; An assembly routine is an ordinary Wasm function in the core module;
;;; calling one is a direct CALL through a fixup that resolves to its
;;; function index.
(defun generate-call-sequence (name style vop options)
  (declare (ignore vop options))
  (ecase style
    ((:raw :none)
     (values
      `((inst call (make-fixup ',name :assembly-routine)))
      `()))))

(defun generate-return-sequence (style)
  (ecase style
    (:raw `((inst return)))
    (:none)))
