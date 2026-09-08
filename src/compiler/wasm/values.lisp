;;;; unknown-values VOPs for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

(define-vop (reset-stack-pointer)
  (:args (ptr :scs (any-reg)))
  (:generator 1
    (move csp-tn ptr)))

(define-vop (%%nip-values)
  (:args (last-nipped-ptr :scs (any-reg) :target dest)
         (last-preserved-ptr :scs (any-reg) :target src)
         (moved-ptrs :scs (any-reg) :more t))
  (:results (r-moved-ptrs :scs (any-reg) :more t))
  (:temporary (:sc any-reg) src)
  (:temporary (:sc any-reg) dest)
  (:temporary (:sc descriptor-reg) temp)
  (:ignore r-moved-ptrs)
  (:generator 1
    (let ((loop (gen-label))
          (done (gen-label)))
      (move src last-preserved-ptr)
      (move dest last-nipped-ptr)
      (load-reg src)
      (load-reg csp-tn)
      (inst i32.ge_u)
      (inst jump-if done)
      (emit-label loop)
      (loadw temp src)
      (storew temp dest)
      (store-reg dest (emit-reg-plus dest n-word-bytes))
      (store-reg src (emit-reg-plus src n-word-bytes))
      (load-reg src)
      (load-reg csp-tn)
      (inst i32.lt_u)
      (inst jump-if loop)
      (emit-label done)
      (move csp-tn dest)
      ;; SRC := the distance moved
      (store-reg src
        (load-reg src)
        (load-reg dest)
        (inst i32.sub))
      (loop for moved = moved-ptrs then (tn-ref-across moved)
            while moved
            do (sc-case (tn-ref-tn moved)
                 ((descriptor-reg any-reg)
                  (store-reg (tn-ref-tn moved)
                    (load-reg (tn-ref-tn moved))
                    (load-reg src)
                    (inst i32.sub)))
                 ((control-stack)
                  (load-stack-tn temp (tn-ref-tn moved))
                  (store-reg temp
                    (load-reg temp)
                    (load-reg src)
                    (inst i32.sub))
                  (store-stack-tn (tn-ref-tn moved) temp)))))))

;;; Push some values onto the stack, returning the start and number of
;;; values pushed as results. It is assumed that the VALS are wired
;;; values. Nvals is the number of values to push.
(define-vop (push-values)
  (:args (vals :more t :scs (descriptor-reg any-reg control-stack)))
  (:results (start :scs (any-reg) :from :load)
            (count :scs (any-reg)))
  (:info nvals)
  (:policy :fast-safe)
  (:temporary (:scs (descriptor-reg)) temp)
  (:generator 20
    (move start csp-tn)
    (store-reg csp-tn (emit-reg-plus csp-tn (* nvals n-word-bytes)))
    (do ((val vals (tn-ref-across val))
         (i 0 (1+ i)))
        ((null val))
      (let ((tn (tn-ref-tn val)))
        (sc-case tn
          ((descriptor-reg any-reg)
           (storew tn start i))
          (control-stack
           (load-stack-tn temp tn)
           (storew temp start i)))))
    (load-immediate-word count (fixnumize nvals))))

;;; Push a list of values on the stack, returning Start and Count as
;;; used in unknown values continuations.
(define-vop (values-list)
  (:args (arg :scs (descriptor-reg) :target list))
  (:arg-types list)
  (:policy :fast-safe)
  (:results (start :scs (any-reg))
            (count :scs (any-reg)))
  (:temporary (:scs (descriptor-reg) :from (:argument 0)) list)
  (:temporary (:scs (descriptor-reg)) temp)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 0
    (let ((loop (gen-label))
          (done (gen-label))
          (bogus (gen-label)))
      (move list arg)
      (move start csp-tn)
      (emit-label loop)
      (load-reg list)
      (inst i32.const nil-value)
      (inst i32.eq)
      (inst jump-if done)
      ;; the element must be a cons
      (load-reg list)
      (inst i32.const lowtag-mask)
      (inst i32.and)
      (inst i32.const list-pointer-lowtag)
      (inst i32.ne)
      (inst jump-if bogus)
      (loadw temp list cons-car-slot list-pointer-lowtag)
      (loadw list list cons-cdr-slot list-pointer-lowtag)
      (storew temp csp-tn 0)
      (store-reg csp-tn (emit-reg-plus csp-tn n-word-bytes))
      (inst jump loop)
      (emit-label bogus)
      (cerror-call vop 'bogus-arg-to-values-list-error list)
      (inst jump loop)
      (emit-label done)
      ;; the count, a fixnum, is the byte size of the values
      (store-reg count
        (load-reg csp-tn)
        (load-reg start)
        (inst i32.sub)))))

;;; Copy the more arg block to the top of the stack so we can use them
;;; as function arguments.
(define-vop (%more-arg-values)
  (:args (context :scs (descriptor-reg any-reg) :target src)
         (num :scs (any-reg) :target count))
  (:arg-types * positive-fixnum)
  (:temporary (:sc any-reg :from (:argument 0)) src)
  (:temporary (:sc any-reg :from (:argument 2)) dst)
  (:temporary (:sc descriptor-reg) temp)
  (:results (start :scs (any-reg))
            (count :scs (any-reg)))
  (:generator 20
    (let ((loop (gen-label))
          (done (gen-label)))
      (move src context)
      (move count num)
      (move start csp-tn)
      (load-reg count)
      (inst i32.eqz)
      (inst jump-if done)
      (move dst start)
      (store-reg csp-tn
        (load-reg csp-tn)
        (load-reg count)
        (inst i32.add))
      (emit-label loop)
      (loadw temp src 0)
      (storew temp dst 0)
      (store-reg src (emit-reg-plus src n-word-bytes))
      (store-reg dst (emit-reg-plus dst n-word-bytes))
      (load-reg dst)
      (load-reg csp-tn)
      (inst i32.ne)
      (inst jump-if loop)
      (emit-label done))))
