;;;; the WebAssembly VM definition of SAP operations

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Moves and coercions:

;;; Move a tagged SAP to an untagged representation.
(define-vop (move-to-sap)
  (:args (x :scs (any-reg descriptor-reg)))
  (:results (y :scs (sap-reg)))
  (:note "pointer to SAP coercion")
  (:generator 1
    (loadw y x sap-pointer-slot other-pointer-lowtag)))
(define-move-vop move-to-sap :move
  (descriptor-reg) (sap-reg))

;;; Move an untagged SAP to a tagged representation.
(define-vop (move-from-sap)
  (:args (sap :scs (sap-reg) :to :save))
  (:results (res :scs (descriptor-reg)))
  (:note "SAP to pointer coercion")
  (:generator 20
    (with-fixed-allocation (res sap-widetag sap-size)
      (storew sap res sap-pointer-slot other-pointer-lowtag))))
(define-move-vop move-from-sap :move
  (sap-reg) (descriptor-reg))

;;; Move untagged sap values.
(define-vop (sap-move)
  (:args (x :target y
            :scs (sap-reg)
            :load-if (not (location= x y))))
  (:results (y :scs (sap-reg)
               :load-if (not (location= x y))))
  (:note "SAP move")
  (:generator 0
    (move y x)))
(define-move-vop sap-move :move
  (sap-reg) (sap-reg))

;;; Move untagged sap arguments/return-values.
(define-vop (move-sap-arg)
  (:args (x :target y
            :scs (sap-reg))
         (fp :scs (any-reg)
             :load-if (not (sc-is y sap-reg))))
  (:results (y))
  (:note "SAP argument move")
  (:generator 0
    (sc-case y
      (sap-reg
       (move y x))
      (sap-stack
       (store-frame-word x fp (tn-offset y))))))
(define-move-vop move-sap-arg :move-arg
  (descriptor-reg sap-reg) (sap-reg))

;;; Use standard MOVE-ARG + coercion to move an untagged sap to a
;;; descriptor passing location.
(define-move-vop move-arg :move-arg
  (sap-reg) (descriptor-reg))

;;;; SAP-INT and INT-SAP

(define-vop (sap-int)
  (:args (sap :scs (sap-reg)))
  (:arg-types system-area-pointer)
  (:results (int :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:translate sap-int)
  (:policy :fast-safe)
  (:generator 1
    (move int sap)))

(define-vop (int-sap)
  (:args (int :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:results (sap :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:translate int-sap)
  (:policy :fast-safe)
  (:generator 1
    (move sap int)))

;;;; POINTER+ and POINTER-

(define-vop (pointer+)
  (:translate sap+)
  (:args (ptr :scs (sap-reg))
         (offset :scs (signed-reg)))
  (:arg-types system-area-pointer signed-num)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:policy :fast-safe)
  (:generator 2
    (store-reg res
      (load-reg ptr)
      (load-reg offset)
      (inst i32.add))))

(define-vop (pointer+-unsigned-c)
  (:translate sap+)
  (:args (ptr :scs (sap-reg)))
  (:info offset)
  (:arg-types system-area-pointer (:constant short-immediate))
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:policy :fast-safe)
  (:generator 1
    (store-reg res
      (load-reg ptr)
      (inst i32.const offset)
      (inst i32.add))))

(define-vop (pointer-)
  (:translate sap-)
  (:args (ptr1 :scs (sap-reg))
         (ptr2 :scs (sap-reg)))
  (:arg-types system-area-pointer system-area-pointer)
  (:policy :fast-safe)
  (:results (res :scs (signed-reg)))
  (:result-types signed-num)
  (:generator 1
    (store-reg res
      (load-reg ptr1)
      (load-reg ptr2)
      (inst i32.sub))))

;;;; mumble-SYSTEM-REF and mumble-SYSTEM-SET

;;; With the address on the stack, push the SIZE element at
;;; address+DISPLACEMENT (an i32 for the integer sizes, an f32 or f64
;;; for the float sizes).
(defun emit-sap-load (size signed displacement)
  (ecase size
    (:byte (emit-load-sized 1 signed displacement))
    (:short (emit-load-sized 2 signed displacement))
    (:word (emit-load-sized 4 signed displacement))
    (:single (emit-load-float :single displacement))
    (:double (emit-load-float :double displacement))))

(defmacro emit-sap-store (size displacement &body value-forms)
  (ecase size
    (:byte `(emit-store-sized 1 ,displacement ,@value-forms))
    (:short `(emit-store-sized 2 ,displacement ,@value-forms))
    (:word `(emit-store-sized 4 ,displacement ,@value-forms))
    (:single `(emit-store-float :single ,displacement ,@value-forms))
    (:double `(emit-store-float :double ,displacement ,@value-forms))))

(defmacro store-sap-result (result size &body value-forms)
  (ecase size
    ((:byte :short :word) `(store-reg ,result ,@value-forms))
    (:single `(store-freg ,result :single ,@value-forms))
    (:double `(store-freg ,result :double ,@value-forms))))

(defmacro load-sap-value (value size)
  (ecase size
    ((:byte :short :word) `(load-reg ,value))
    (:single `(load-freg ,value :single))
    (:double `(load-freg ,value :double))))

(macrolet ((def-system-ref-and-set
               (ref-name set-name sc type size &key signed)
             `(progn
                ,@(when (member ref-name '(sap-ref-32 sap-ref-lispobj sap-ref-sap))
                    ;; One thread: compare-and-swap is a load, a compare
                    ;; and a conditional store.
                    `((define-vop (,(symbolicate "CAS-" ref-name))
                        (:translate (cas ,ref-name))
                        (:policy :fast-safe)
                        (:args (oldval :scs (,sc) :to :save)
                               (newval :scs (,sc) :to :save)
                               (sap :scs (sap-reg) :to :save)
                               (offset :scs (signed-reg) :to :save))
                        (:arg-types ,type ,type system-area-pointer signed-num)
                        (:results (result :scs (,sc) :from :load))
                        (:result-types ,type)
                        (:generator 5
                          (let ((done (gen-label)))
                            (store-reg result
                              (load-reg sap)
                              (load-reg offset)
                              (inst i32.add)
                              (inst i32.load 0))
                            (load-reg result)
                            (load-reg oldval)
                            (inst i32.ne)
                            (inst jump-if done)
                            (load-reg sap)
                            (load-reg offset)
                            (inst i32.add)
                            (load-reg newval)
                            (inst i32.store 0)
                            (emit-label done))))))
                (define-vop (,ref-name)
                  (:translate ,ref-name)
                  (:policy :fast-safe)
                  (:args (object :scs (sap-reg))
                         (offset :scs (signed-reg)))
                  (:arg-types system-area-pointer signed-num)
                  (:results (result :scs (,sc)))
                  (:result-types ,type)
                  (:generator 5
                    (store-sap-result result ,size
                      (load-reg object)
                      (load-reg offset)
                      (inst i32.add)
                      (emit-sap-load ,size ,signed 0))))
                (define-vop (,(symbolicate ref-name "-C"))
                  (:translate ,ref-name)
                  (:policy :fast-safe)
                  (:args (sap :scs (sap-reg)))
                  (:arg-types system-area-pointer
                              (:constant short-immediate))
                  (:info offset)
                  (:results (result :scs (,sc)))
                  (:result-types ,type)
                  (:generator 4
                    (store-sap-result result ,size
                      (load-reg sap)
                      (emit-sap-load ,size ,signed offset))))
                (define-vop (,set-name)
                  (:translate ,set-name)
                  (:policy :fast-safe)
                  (:args (value :scs (,sc))
                         (object :scs (sap-reg))
                         (offset :scs (signed-reg)))
                  (:arg-types ,type system-area-pointer signed-num)
                  (:generator 5
                    (load-reg object)
                    (load-reg offset)
                    (inst i32.add)
                    (emit-sap-store ,size 0
                      (load-sap-value value ,size))))
                (define-vop (,(symbolicate set-name "-C"))
                  (:translate ,set-name)
                  (:policy :fast-safe)
                  (:args (value :scs (,sc))
                         (sap :scs (sap-reg)))
                  (:arg-types ,type system-area-pointer (:constant short-immediate))
                  (:info offset)
                  (:generator 4
                    (load-reg sap)
                    (emit-sap-store ,size offset
                      (load-sap-value value ,size)))))))
  (def-system-ref-and-set sap-ref-8 %set-sap-ref-8
    unsigned-reg positive-fixnum :byte :signed nil)
  (def-system-ref-and-set signed-sap-ref-8 %set-signed-sap-ref-8
    signed-reg tagged-num :byte :signed t)
  (def-system-ref-and-set sap-ref-16 %set-sap-ref-16
    unsigned-reg positive-fixnum :short :signed nil)
  (def-system-ref-and-set signed-sap-ref-16 %set-signed-sap-ref-16
    signed-reg tagged-num :short :signed t)
  (def-system-ref-and-set sap-ref-32 %set-sap-ref-32
    unsigned-reg unsigned-num :word :signed nil)
  (def-system-ref-and-set signed-sap-ref-32 %set-signed-sap-ref-32
    signed-reg signed-num :word :signed t)
  (def-system-ref-and-set sap-ref-sap %set-sap-ref-sap
    sap-reg system-area-pointer :word)
  (def-system-ref-and-set sap-ref-lispobj %set-sap-ref-lispobj
    descriptor-reg * :word)
  (def-system-ref-and-set sap-ref-single %set-sap-ref-single
    single-reg single-float :single)
  (def-system-ref-and-set sap-ref-double %set-sap-ref-double
    double-reg double-float :double))

;;; Noise to convert normal lisp data objects into SAPs.

(define-vop (vector-sap)
  (:translate vector-sap)
  (:policy :fast-safe)
  (:args (vector :scs (descriptor-reg)))
  (:results (sap :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
    (store-reg sap
      (load-reg vector)
      (inst i32.const (- (* vector-data-offset n-word-bytes) other-pointer-lowtag))
      (inst i32.add))))
