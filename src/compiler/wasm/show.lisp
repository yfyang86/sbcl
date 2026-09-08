;;;; VOPs which are useful for following the progress of the system
;;;; early in boot

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;; The runtime's DEBUG_PRINT takes the object as an i32 and returns it;
;;; it is called like any foreign function (see c-call.lisp).
(define-vop (print)
  (:args (object :scs (descriptor-reg any-reg)))
  (:results (result :scs (descriptor-reg)))
  (:save-p t)
  (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
  (:vop-var vop)
  (:generator 100
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (store-stack-tn nfp-save cur-nfp))
      (store-reg result
        (load-reg object)
        (inst i32.const (make-fixup "debug_print" :foreign))
        (inst call_indirect (make-fixup '((:i32) (:i32)) :function-type)))
      (when cur-nfp
        (load-stack-tn cur-nfp nfp-save)))))
