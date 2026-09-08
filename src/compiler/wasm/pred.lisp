;;;; predicate VOPs for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;; The unconditional branch, emitted when we can't drop through to the
;;; desired destination.
(define-vop (branch)
  (:info dest)
  (:generator 3
    (inst jump dest)))

;;; Conditional VOPs on this target branch themselves (:CONDITIONAL with
;;; TARGET and NOT-P), so the flag-based BRANCH-IF is never selected.
(define-vop (branch-if)
  (:info dest flags not-p)
  (:ignore dest not-p flags)
  (:generator 0
    (error "BRANCH-IF should not be needed on this target.")))

;;; No conditional-move conversion: the engine does that.
(defun convert-conditional-move-p (dst-tn)
  (declare (ignore dst-tn))
  nil)

(define-vop (if-eq)
  (:args (x :scs (any-reg descriptor-reg))
         (y :scs (any-reg descriptor-reg)))
  (:conditional)
  (:info target not-p)
  (:policy :fast-safe)
  (:translate eq)
  (:generator 3
    (load-reg x)
    (load-reg y)
    (if not-p (inst i32.ne) (inst i32.eq))
    (inst jump-if target)))
