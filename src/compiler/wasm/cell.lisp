;;;; the VM definition of various primitive memory access VOPs for the
;;;; WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Data object ref/set stuff.

(define-vop (slot)
  (:args (object :scs (descriptor-reg)))
  (:info name offset lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg any-reg)))
  (:generator 1
    (loadw result object offset lowtag)))

(define-vop (set-slot)
  (:args (object :scs (descriptor-reg))
         (value :scs (descriptor-reg any-reg)))
  (:info name offset lowtag)
  (:ignore name)
  (:results)
  (:generator 1
    (storew value object offset lowtag)))

;;; One thread: a compare-and-swap is a load, a compare and a
;;; conditional store.
(defun emit-compare-and-swap-word (result object displacement old new)
  (let ((done (gen-label)))
    (store-reg result
      (load-reg object)
      (emit-load-word displacement))
    (load-reg result)
    (load-reg old)
    (inst i32.ne)
    (inst jump-if done)
    (load-reg object)
    (emit-store-word displacement
      (load-reg new))
    (emit-label done)))

(define-vop (compare-and-swap-slot)
  (:args (object :scs (descriptor-reg) :to :save)
         (old :scs (descriptor-reg any-reg) :to :save)
         (new :scs (descriptor-reg any-reg) :to :save))
  (:info name offset lowtag)
  (:ignore name)
  (:results (result :scs (descriptor-reg) :from :load))
  (:generator 5
    (emit-compare-and-swap-word result object (- (* offset n-word-bytes) lowtag) old new)))

;;;; Symbol hacking VOPs:

(define-vop (%compare-and-swap-symbol-value)
  (:translate %compare-and-swap-symbol-value)
  (:args (symbol :scs (descriptor-reg) :to :save)
         (old :scs (descriptor-reg any-reg) :to :save)
         (new :scs (descriptor-reg any-reg) :to :save))
  (:results (result :scs (descriptor-reg any-reg) :from :load))
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 15
    (emit-compare-and-swap-word result symbol
                                (- (* symbol-value-slot n-word-bytes) other-pointer-lowtag)
                                old new)
    (load-reg result)
    (inst i32.const unbound-marker-widetag)
    (inst i32.eq)
    (inst jump-if (generate-error-code vop 'unbound-symbol-error symbol))))

;;; The compiler likes to be able to directly SET symbols.
(define-vop (set cell-set)
  (:variant symbol-value-slot other-pointer-lowtag))

;;; Do a cell ref with an error check for being unbound.
(define-vop (checked-cell-ref)
  (:args (object :scs (descriptor-reg) :to :save))
  (:results (value :scs (descriptor-reg any-reg)))
  (:policy :fast-safe)
  (:vop-var vop)
  (:save-p :compute-only))

;;; With unbound check.
(define-vop (symbol-value checked-cell-ref)
  (:translate symbol-value)
  (:generator 9
    (loadw value object symbol-value-slot other-pointer-lowtag)
    (let ((err-lab (generate-error-code vop 'unbound-symbol-error object)))
      (load-reg value)
      (inst i32.const unbound-marker-widetag)
      (inst i32.eq)
      (inst jump-if err-lab))))

(define-vop (boundp)
  (:args (object :scs (descriptor-reg)))
  (:conditional)
  (:info target not-p)
  (:policy :fast-safe)
  (:translate boundp)
  (:generator 9
    (load-reg object)
    (emit-load-word (- (* symbol-value-slot n-word-bytes) other-pointer-lowtag))
    (inst i32.const unbound-marker-widetag)
    (if not-p (inst i32.eq) (inst i32.ne))
    (inst jump-if target)))

(define-vop (fast-symbol-value cell-ref)
  (:variant symbol-value-slot other-pointer-lowtag)
  (:policy :fast)
  (:translate symbol-value))

(define-vop (%set-symbol-global-value cell-set)
  (:variant symbol-value-slot other-pointer-lowtag))

(define-vop (fast-symbol-global-value cell-ref)
  (:variant symbol-value-slot other-pointer-lowtag)
  (:policy :fast)
  (:translate symbol-global-value))

(define-vop (symbol-global-value)
  (:policy :fast-safe)
  (:translate symbol-global-value)
  (:args (object :scs (descriptor-reg) :to :save))
  (:results (value :scs (descriptor-reg any-reg)))
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 9
    (let ((err-lab (generate-error-code vop 'unbound-symbol-error object)))
      (loadw value object symbol-value-slot other-pointer-lowtag)
      (load-reg value)
      (inst i32.const unbound-marker-widetag)
      (inst i32.eq)
      (inst jump-if err-lab))))

;;;; Fdefinition (fdefn) objects.

(define-vop (safe-fdefn-fun)
  (:translate safe-fdefn-fun)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :to :save))
  (:results (value :scs (descriptor-reg any-reg)))
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 10
    (loadw value object fdefn-fun-slot other-pointer-lowtag)
    (let ((err-lab (generate-error-code vop 'undefined-fun-error object)))
      (load-reg value)
      (inst i32.const nil-value)
      (inst i32.eq)
      (inst jump-if err-lab))))

;;; The raw-addr slot of an fdefn holds the entry of the function in
;;; the funcref table; the trampolines it refers to belong to the full
;;; call convention (doc/wasm-port/04-sprints.md, Sprint 3).
(define-vop (set-fdefn-fun)
  (:policy :fast-safe)
  (:args (function :scs (descriptor-reg))
         (fdefn :scs (descriptor-reg)))
  (:generator 3
    (vop-not-yet-implemented 'set-fdefn-fun function fdefn)))

(define-vop (fdefn-makunbound)
  (:policy :fast-safe)
  (:translate fdefn-makunbound)
  (:args (fdefn :scs (descriptor-reg)))
  (:generator 38
    (vop-not-yet-implemented 'fdefn-makunbound fdefn)))

;;;; Binding and Unbinding.

;;; Establish VALUE as a binding for SYMBOL. Save the old value and the
;;; symbol on the binding stack and stuff the new value into the symbol.
(define-vop (dynbind)
  (:args (value :scs (any-reg descriptor-reg) :to :save)
         (symbol :scs (descriptor-reg) :to :save))
  (:temporary (:scs (descriptor-reg)) temp)
  (:temporary (:scs (any-reg)) bsp-temp)
  (:generator 5
    (loadw temp symbol symbol-value-slot other-pointer-lowtag)
    (load-binding-stack-pointer bsp-temp)
    (store-reg bsp-temp
      (load-reg bsp-temp)
      (inst i32.const (* binding-size n-word-bytes))
      (inst i32.add))
    (store-binding-stack-pointer bsp-temp)
    (storew temp bsp-temp (- binding-value-slot binding-size))
    (storew symbol bsp-temp (- binding-symbol-slot binding-size))
    (storew value symbol symbol-value-slot other-pointer-lowtag)))

(define-vop (unbind)
  (:temporary (:scs (descriptor-reg)) symbol value)
  (:temporary (:scs (any-reg)) bsp-temp)
  (:generator 0
    (load-binding-stack-pointer bsp-temp)
    (loadw symbol bsp-temp (- binding-symbol-slot binding-size))
    (loadw value bsp-temp (- binding-value-slot binding-size))
    (storew value symbol symbol-value-slot other-pointer-lowtag)
    (load-reg bsp-temp)
    (emit-store-word (ash (- binding-symbol-slot binding-size) word-shift)
      (inst i32.const 0))
    (load-reg bsp-temp)
    (emit-store-word (ash (- binding-value-slot binding-size) word-shift)
      (inst i32.const 0))
    (store-reg bsp-temp
      (load-reg bsp-temp)
      (inst i32.const (* binding-size n-word-bytes))
      (inst i32.sub))
    (store-binding-stack-pointer bsp-temp)))

(define-vop (unbind-to-here)
  (:args (arg :scs (descriptor-reg any-reg) :to :save))
  (:temporary (:scs (descriptor-reg)) symbol value)
  (:temporary (:scs (any-reg)) bsp)
  (:generator 0
    (let ((loop (gen-label))
          (skip (gen-label))
          (done (gen-label)))
      (load-binding-stack-pointer bsp)
      (load-reg arg)
      (load-reg bsp)
      (inst i32.eq)
      (inst jump-if done)
      (emit-label loop)
      (loadw symbol bsp (- binding-symbol-slot binding-size))
      (load-reg symbol)
      (inst i32.eqz)
      (inst jump-if skip)
      (loadw value bsp (- binding-value-slot binding-size))
      (storew value symbol symbol-value-slot other-pointer-lowtag)
      (load-reg bsp)
      (emit-store-word (ash (- binding-symbol-slot binding-size) word-shift)
        (inst i32.const 0))
      (emit-label skip)
      (load-reg bsp)
      (emit-store-word (ash (- binding-value-slot binding-size) word-shift)
        (inst i32.const 0))
      (store-reg bsp
        (load-reg bsp)
        (inst i32.const (* binding-size n-word-bytes))
        (inst i32.sub))
      (load-reg arg)
      (load-reg bsp)
      (inst i32.ne)
      (inst jump-if loop)
      (emit-label done)
      (store-binding-stack-pointer bsp))))

;;;; Closure indexing.

(define-full-reffer closure-index-ref *
  closure-info-offset fun-pointer-lowtag
  (descriptor-reg any-reg) * %closure-index-ref)

(define-full-setter %closure-index-set *
  closure-info-offset fun-pointer-lowtag
  (descriptor-reg any-reg) * %closure-index-set)

(define-full-reffer funcallable-instance-info *
  funcallable-instance-info-offset fun-pointer-lowtag
  (descriptor-reg any-reg) * %funcallable-instance-info)

(define-vop (closure-ref)
  (:args (object :scs (descriptor-reg)))
  (:results (value :scs (descriptor-reg any-reg)))
  (:info offset)
  (:generator 4
    (loadw value object (+ closure-info-offset offset) fun-pointer-lowtag)))

(define-vop (closure-init)
  (:args (object :scs (descriptor-reg))
         (value :scs (descriptor-reg any-reg)))
  (:info offset dx)
  (:ignore dx)
  (:generator 4
    (storew value object (+ closure-info-offset offset) fun-pointer-lowtag)))

(define-vop (closure-init-from-fp)
  (:args (object :scs (descriptor-reg)))
  (:info offset)
  (:generator 4
    (storew cfp-tn object (+ closure-info-offset offset) fun-pointer-lowtag)))

;;;; Value Cell hackery.

(define-vop (value-cell-set cell-set)
  (:variant value-cell-value-slot other-pointer-lowtag))

;;;; Instance hackery:

(define-vop ()
  (:policy :fast-safe)
  (:translate %instance-length)
  (:args (struct :scs (descriptor-reg)))
  (:results (res :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 4
    (store-reg res
      (load-reg struct)
      (emit-load-word (- instance-pointer-lowtag))
      (inst i32.const instance-length-shift)
      (inst i32.shr_u))))

(define-full-reffer instance-index-ref * instance-slots-offset
  instance-pointer-lowtag (descriptor-reg any-reg) * %instance-ref)

(define-full-setter instance-index-set * instance-slots-offset
  instance-pointer-lowtag (descriptor-reg any-reg) * %instance-set)

(defmacro define-full-casser (name type offset lowtag scs eltype &optional translate)
  `(define-vop (,name)
     ,@(when translate `((:translate ,translate)))
     (:policy :fast-safe)
     (:args (object :scs (descriptor-reg) :to :save)
            (index :scs (any-reg) :to :save)
            (old-value :scs ,scs :to :save)
            (new-value :scs ,scs :to :save))
     (:arg-types ,type tagged-num ,eltype ,eltype)
     (:results (result :scs ,scs :from :load))
     (:result-types ,eltype)
     (:generator 5
       (let ((done (gen-label))
             (displacement (- (* ,offset n-word-bytes) ,lowtag)))
         (store-reg result
           (emit-indexed-address object index n-word-bytes)
           (emit-load-word displacement))
         (load-reg result)
         (load-reg old-value)
         (inst i32.ne)
         (inst jump-if done)
         (emit-indexed-address object index n-word-bytes)
         (emit-store-word displacement
           (load-reg new-value))
         (emit-label done)))))

(define-full-casser instance-index-cas * instance-slots-offset
  instance-pointer-lowtag (descriptor-reg any-reg) * %instance-cas)

;;;; Raw instance slot accessors

(macrolet ((define-raw-slot-word-vops (name value-sc value-primtype)
             `(progn
                (define-full-reffer ,(symbolicate "%RAW-INSTANCE-REF/" name) * instance-slots-offset
                  instance-pointer-lowtag (,value-sc) ,value-primtype
                  ,(symbolicate "%RAW-INSTANCE-REF/" name))
                (define-full-setter ,(symbolicate "%RAW-INSTANCE-SET/" name) * instance-slots-offset
                  instance-pointer-lowtag (,value-sc) ,value-primtype
                  ,(symbolicate "%RAW-INSTANCE-SET/" name))
                (define-full-casser ,(symbolicate "RAW-INSTANCE-CAS/" name) instance instance-slots-offset
                  instance-pointer-lowtag (,value-sc) ,value-primtype
                  ,(symbolicate "%RAW-INSTANCE-CAS/" name)))))
  (define-raw-slot-word-vops word unsigned-reg unsigned-num)
  (define-raw-slot-word-vops signed-word signed-reg signed-num))

(macrolet ((define-raw-slot-float-vops (name value-primtype value-sc size format &optional complexp)
             (let ((ref-vop (symbolicate "%RAW-INSTANCE-REF/" name))
                   (set-vop (symbolicate "%RAW-INSTANCE-SET/" name)))
               `(progn
                  (,(if complexp
                        'define-complex-float-reffer
                        'define-float-reffer)
                   ,ref-vop * ,size ,format instance-slots-offset
                   instance-pointer-lowtag (,value-sc) ,value-primtype nil "raw instance access"
                   ,ref-vop)
                  (,(if complexp
                        'define-complex-float-setter
                        'define-float-setter)
                   ,set-vop * ,size ,format instance-slots-offset
                   instance-pointer-lowtag (,value-sc) ,value-primtype nil "raw instance store"
                   ,set-vop)))))
  (define-raw-slot-float-vops single single-float single-reg 4 :single)
  (define-raw-slot-float-vops double double-float double-reg 8 :double)
  (define-raw-slot-float-vops complex-single complex-single-float complex-single-reg 4 :single t)
  (define-raw-slot-float-vops complex-double complex-double-float complex-double-reg 8 :double t))

(define-vop (raw-instance-incf/word)
  (:translate %raw-instance-atomic-incf/word)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :to :save)
         (index :scs (any-reg) :to :save)
         (diff :scs (unsigned-reg) :to :save))
  (:arg-types * tagged-num unsigned-num)
  (:results (result :scs (unsigned-reg) :from :load))
  (:result-types unsigned-num)
  (:generator 5
    (let ((displacement (- (* instance-slots-offset n-word-bytes) instance-pointer-lowtag)))
      (store-reg result
        (emit-indexed-address object index n-word-bytes)
        (emit-load-word displacement))
      (emit-indexed-address object index n-word-bytes)
      (emit-store-word displacement
        (load-reg result)
        (load-reg diff)
        (inst i32.add)))))
