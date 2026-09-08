;;;; WebAssembly compiler support for the debugger

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

(define-vop (current-fp-sap)
  (:translate current-fp)
  (:policy :fast-safe)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 1
    (move res cfp-tn)))

;;; Find the code object of a function (or of any object whose header
;;; data is its offset in words from the code object), NIL when the
;;; header data is zero.
(define-vop (code-from-mumble)
  (:policy :fast-safe)
  (:args (thing :scs (descriptor-reg) :to :save))
  (:results (code :scs (descriptor-reg)))
  (:variant-vars lowtag)
  (:generator 5
    (let ((done (gen-label)))
      ;; header data (words back to the code object) into tmp
      (store-reg tmp-tn
        (load-reg thing)
        (emit-load-word (- lowtag))
        (inst i32.const n-widetag-bits)
        (inst i32.shr_u))
      (load-immediate-word code nil-value)
      (load-reg tmp-tn)
      (inst i32.eqz)
      (inst jump-if done)
      (store-reg code
        (load-reg thing)
        (load-reg tmp-tn)
        (inst i32.const word-shift)
        (inst i32.shl)
        (inst i32.sub)
        (unless (= lowtag other-pointer-lowtag)
          (inst i32.const (- other-pointer-lowtag lowtag))
          (inst i32.add)))
      (emit-label done))))

(define-vop (code-from-fun code-from-mumble)
  (:translate sb-di::fun-code-header)
  (:variant fun-pointer-lowtag))

(define-vop (%make-lisp-obj)
  (:policy :fast-safe)
  (:translate %make-lisp-obj)
  (:args (value :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:results (result :scs (descriptor-reg)))
  (:generator 1
    (move result value)))

(define-vop (get-lisp-obj-address)
  (:policy :fast-safe)
  (:translate sb-di::get-lisp-obj-address)
  (:args (thing :scs (descriptor-reg any-reg)))
  (:results (result :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:generator 1
    (move result thing)))
