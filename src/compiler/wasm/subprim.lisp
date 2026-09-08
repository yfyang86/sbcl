;;;; linkage information for standard static functions, and random vops
;;;; for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; LENGTH

(define-vop (length/list)
  (:translate length)
  (:args (object :scs (descriptor-reg) :target ptr))
  (:arg-types list)
  (:temporary (:scs (descriptor-reg) :from (:argument 0)) ptr)
  (:temporary (:scs (any-reg) :to (:result 0) :target result)
              count)
  (:results (result :scs (any-reg descriptor-reg)))
  (:policy :fast-safe)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 50
    (let ((loop (gen-label))
          (done (gen-label))
          (not-list (gen-label)))
      (move ptr object)
      (load-immediate-word count 0)
      (emit-label loop)
      (load-reg ptr)
      (inst i32.const nil-value)
      (inst i32.eq)
      (inst jump-if done)
      (%test-lowtag ptr nil not-list t list-pointer-lowtag)
      (loadw ptr ptr cons-cdr-slot list-pointer-lowtag)
      (store-reg count (emit-reg-plus count (fixnumize 1)))
      (inst jump loop)
      (emit-label not-list)
      (cerror-call vop 'object-not-list-error ptr)
      (inst jump loop)
      (emit-label done)
      (move result count))))
