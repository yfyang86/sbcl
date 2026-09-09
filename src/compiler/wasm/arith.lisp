;;;; the VM definition of arithmetic VOPs for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Conventions
;;;;
;;;; Every VOP reads its operands from the register file, computes on the
;;;; operand stack and stores each result with a single STORE-REG. A
;;;; result may therefore share a register with an argument as long as no
;;;; later store of the same VOP reads that argument again; multi-result
;;;; VOPs keep their arguments live to :SAVE so that the order of the
;;;; stores does not matter. Wasm shift counts are taken modulo 32, which
;;;; matches the register-machine backends; the ASH VOPs handle the
;;;; larger counts explicitly.

(define-vop (fast-safe-arith-op)
  (:policy :fast-safe))

(define-vop (fixnum-unop fast-safe-arith-op)
  (:args (x :scs (any-reg)))
  (:results (res :scs (any-reg)))
  (:note "inline fixnum arithmetic")
  (:arg-types tagged-num)
  (:result-types tagged-num))

(define-vop (signed-unop fast-safe-arith-op)
  (:args (x :scs (signed-reg)))
  (:results (res :scs (signed-reg)))
  (:note "inline (signed-byte 32) arithmetic")
  (:arg-types signed-num)
  (:result-types signed-num))

(define-vop (fast-negate/fixnum fixnum-unop)
  (:translate %negate)
  (:generator 1
    (store-reg res
      (inst i32.const 0)
      (load-reg x)
      (inst i32.sub))))

(define-vop (fast-negate/signed signed-unop)
  (:translate %negate)
  (:generator 2
    (store-reg res
      (inst i32.const 0)
      (load-reg x)
      (inst i32.sub))))

(define-vop (fast-lognot/fixnum fixnum-unop)
  (:translate lognot)
  (:generator 1
    (store-reg res
      (load-reg x)
      (inst i32.const (fixnumize -1))
      (inst i32.xor))))

(define-vop (fast-lognot/signed signed-unop)
  (:translate lognot)
  (:generator 2
    (store-reg res
      (load-reg x)
      (inst i32.const -1)
      (inst i32.xor))))

;;;; Binary fixnum operations.

;;; Assume that any constant operand is the second arg...

(define-vop (fast-fixnum-binop fast-safe-arith-op)
  (:args (x :scs (any-reg))
         (y :scs (any-reg)))
  (:arg-types tagged-num tagged-num)
  (:results (r :scs (any-reg)))
  (:result-types tagged-num)
  (:note "inline fixnum arithmetic"))

(define-vop (fast-unsigned-binop fast-safe-arith-op)
  (:args (x :scs (unsigned-reg))
         (y :scs (unsigned-reg)))
  (:arg-types unsigned-num unsigned-num)
  (:results (r :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:note "inline (unsigned-byte 32) arithmetic"))

(define-vop (fast-signed-binop fast-safe-arith-op)
  (:args (x :scs (signed-reg))
         (y :scs (signed-reg)))
  (:arg-types signed-num signed-num)
  (:results (r :scs (signed-reg)))
  (:result-types signed-num)
  (:note "inline (signed-byte 32) arithmetic"))

(define-vop (fast-fixnum-binop-c fast-safe-arith-op)
  (:args (x :scs (any-reg)))
  (:info y)
  (:arg-types tagged-num (:constant short-immediate-fixnum))
  (:results (r :scs (any-reg)))
  (:result-types tagged-num)
  (:note "inline arithmetic"))

(define-vop (fast-unsigned-binop-c fast-safe-arith-op)
  (:args (x :scs (unsigned-reg)))
  (:info y)
  (:arg-types unsigned-num (:constant short-immediate))
  (:results (r :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:note "inline unsigned unboxed arithmetic"))

(define-vop (fast-signed-binop-c fast-safe-arith-op)
  (:args (x :scs (signed-reg)))
  (:info y)
  (:arg-types signed-num (:constant short-immediate))
  (:results (r :scs (signed-reg)))
  (:result-types signed-num)
  (:note "inline signed unboxed arithmetic"))

(defmacro define-binop (translate cost untagged-cost op)
  `(progn
     (define-vop (,(symbolicate "FAST-" translate "/FIXNUM=>FIXNUM")
                  fast-fixnum-binop)
       (:translate ,translate)
       (:generator ,(1+ cost)
         (store-reg r (load-reg x) (load-reg y) (inst ,op))))
     (define-vop (,(symbolicate "FAST-" translate "/SIGNED=>SIGNED")
                  fast-signed-binop)
       (:translate ,translate)
       (:generator ,(1+ untagged-cost)
         (store-reg r (load-reg x) (load-reg y) (inst ,op))))
     (define-vop (,(symbolicate "FAST-" translate "/UNSIGNED=>UNSIGNED")
                  fast-unsigned-binop)
       (:translate ,translate)
       (:generator ,(1+ untagged-cost)
         (store-reg r (load-reg x) (load-reg y) (inst ,op))))
     (define-vop (,(symbolicate "FAST-" translate "-C/FIXNUM=>FIXNUM")
                  fast-fixnum-binop-c)
       (:translate ,translate)
       (:generator ,cost
         (store-reg r (load-reg x) (inst i32.const (fixnumize y)) (inst ,op))))
     (define-vop (,(symbolicate "FAST-" translate "-C/SIGNED=>SIGNED")
                  fast-signed-binop-c)
       (:translate ,translate)
       (:generator ,untagged-cost
         (store-reg r (load-reg x) (inst i32.const y) (inst ,op))))
     (define-vop (,(symbolicate "FAST-" translate "-C/UNSIGNED=>UNSIGNED")
                  fast-unsigned-binop-c)
       (:translate ,translate)
       (:generator ,untagged-cost
         (store-reg r (load-reg x) (inst i32.const y) (inst ,op))))))

(define-binop + 1 5 i32.add)
(define-binop - 1 5 i32.sub)
(define-binop logior 1 3 i32.or)
(define-binop logxor 1 3 i32.xor)
(define-binop logand 1 3 i32.and)

(define-vop (fast-logand/signed-unsigned=>unsigned fast-logand/unsigned=>unsigned)
  (:args (x :scs (signed-reg))
         (y :scs (unsigned-reg)))
  (:arg-types signed-num unsigned-num)
  (:translate logand))

(define-vop (fast-logand-c/signed-unsigned=>unsigned fast-logand-c/unsigned=>unsigned)
  (:args (x :scs (signed-reg)))
  (:arg-types signed-num (:constant (eql #.(ldb (byte 32 0) -1))))
  (:translate logand)
  (:ignore y)
  (:generator 1
    (move r x)))

(define-source-transform logeqv (&rest args)
  (if (oddp (length args))
      `(logxor ,@args)
      `(lognot (logxor ,@args))))
(define-source-transform logandc1 (x y)
  `(logand (lognot ,x) ,y))
(define-source-transform logandc2 (x y)
  `(logand ,x (lognot ,y)))
(define-source-transform logorc1 (x y)
  `(logior (lognot ,x) ,y))
(define-source-transform logorc2 (x y)
  `(logior ,x (lognot ,y)))
(define-source-transform lognor (x y)
  `(lognot (logior ,x ,y)))
(define-source-transform lognand (x y)
  `(lognot (logand ,x ,y)))

;;;; Shifting

(define-vop (fast-ash-left-c/fixnum=>fixnum)
  (:translate ash)
  (:policy :fast-safe)
  (:args (number :scs (any-reg)))
  (:info amount)
  (:arg-types tagged-num (:constant unsigned-byte))
  (:results (result :scs (any-reg)))
  (:result-types tagged-num)
  (:note "inline ASH")
  (:generator 1
    (if (< amount n-word-bits)
        (store-reg result (load-reg number) (inst i32.const amount) (inst i32.shl))
        (load-immediate-word result 0))))

(define-vop (fast-ash-right-c/fixnum=>fixnum)
  (:translate ash)
  (:policy :fast-safe)
  (:args (number :scs (any-reg)))
  (:info amount)
  (:arg-types tagged-num (:constant (integer * -1)))
  (:results (result :scs (any-reg)))
  (:result-types tagged-num)
  (:note "inline ASH")
  (:generator 1
    (store-reg result
      (load-reg number)
      (inst i32.const (min (- amount) (1- n-word-bits)))
      (inst i32.shr_s)
      (inst i32.const (lognot fixnum-tag-mask))
      (inst i32.and))))

(define-vop (fast-ash-c/unsigned=>unsigned)
  (:translate ash)
  (:policy :fast-safe)
  (:args (number :scs (unsigned-reg)))
  (:info amount)
  (:arg-types unsigned-num (:constant integer))
  (:results (result :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:note "inline ASH")
  (:generator 1
    (cond ((< (- n-word-bits) amount n-word-bits)
           (store-reg result
             (load-reg number)
             (inst i32.const (abs amount))
             (if (plusp amount) (inst i32.shl) (inst i32.shr_u))))
          (t
           (load-immediate-word result 0)))))

(define-vop (fast-ash-c/signed=>signed)
  (:translate ash)
  (:policy :fast-safe)
  (:args (number :scs (signed-reg)))
  (:info amount)
  (:arg-types signed-num (:constant integer))
  (:results (result :scs (signed-reg)))
  (:result-types signed-num)
  (:note "inline ASH")
  (:generator 1
    (cond ((< (- n-word-bits) amount n-word-bits)
           (store-reg result
             (load-reg number)
             (inst i32.const (abs amount))
             (if (plusp amount) (inst i32.shl) (inst i32.shr_s))))
          ((>= amount n-word-bits)
           (load-immediate-word result 0))
          (t
           (store-reg result
             (load-reg number)
             (inst i32.const (1- n-word-bits))
             (inst i32.shr_s))))))

;;; A variable shift in either direction. Left shifts cannot overflow
;;; (the result type guarantees it); right shifts are done in i64 with the
;;; count clamped to 63, so that counts of 32 and more give the sign fill
;;; (signed) or zero (unsigned) without a branch. SELECT evaluates both
;;; arms, which is fine since neither can trap.
(define-vop (fast-ash/signed/unsigned)
  (:note "inline ASH")
  (:args (number :to :save)
         (amount :to :save))
  (:results (result))
  (:policy :fast-safe)
  (:temporary (:sc unsigned-reg) count)
  (:variant-vars variant)
  (:generator 3
    ;; count = -amount (as an unsigned word; -2^31 stays large)
    (store-reg count
      (inst i32.const 0)
      (load-reg amount)
      (inst i32.sub))
    (store-reg result
      ;; left shift
      (load-reg number)
      (load-reg amount)
      (inst i32.shl)
      ;; right shift, in i64, by min(count, 63)
      (load-reg number)
      (ecase variant
        (:signed (inst i64.extend_i32_s))
        (:unsigned (inst i64.extend_i32_u)))
      (load-reg count)
      (inst i32.const 63)
      (load-reg count)
      (inst i32.const 63)
      (inst i32.lt_u)
      (inst select)
      (inst i64.extend_i32_u)
      (ecase variant
        (:signed (inst i64.shr_s))
        (:unsigned (inst i64.shr_u)))
      (inst i32.wrap_i64)
      ;; amount >= 0 selects the left shift
      (load-reg amount)
      (inst i32.const 0)
      (inst i32.ge_s)
      (inst select))))

(define-vop (fast-ash/unsigned=>unsigned fast-ash/signed/unsigned)
  (:args (number :scs (unsigned-reg) :to :save)
         (amount :scs (signed-reg) :to :save))
  (:arg-types unsigned-num signed-num)
  (:results (result :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:translate ash)
  (:variant :unsigned))

(define-vop (fast-ash/signed=>signed fast-ash/signed/unsigned)
  (:args (number :scs (signed-reg) :to :save)
         (amount :scs (signed-reg) :to :save))
  (:arg-types signed-num signed-num)
  (:results (result :scs (signed-reg)))
  (:result-types signed-num)
  (:translate ash)
  (:variant :signed))

(macrolet ((def (name sc-type type result-type cost)
             `(define-vop (,name)
                (:note "inline ASH")
                (:translate ash)
                (:args (number :scs (,sc-type))
                       (amount :scs (signed-reg unsigned-reg)))
                (:arg-types ,type positive-fixnum)
                (:results (result :scs (,result-type)))
                (:result-types ,type)
                (:policy :fast-safe)
                (:generator ,cost
                  (store-reg result
                    (load-reg number)
                    (load-reg amount)
                    (inst i32.shl))))))
  (def fast-ash-left/fixnum=>fixnum any-reg tagged-num any-reg 2)
  (def fast-ash-left/signed=>signed signed-reg signed-num signed-reg 3)
  (def fast-ash-left/unsigned=>unsigned unsigned-reg unsigned-num unsigned-reg 3))

(define-vop (fast-%ash/right/unsigned)
  (:translate %ash/right)
  (:policy :fast-safe)
  (:args (number :scs (unsigned-reg))
         (amount :scs (unsigned-reg)))
  (:arg-types unsigned-num unsigned-num)
  (:results (result :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:generator 4
    (store-reg result
      (load-reg number)
      (load-reg amount)
      (inst i32.shr_u))))

(define-vop (fast-%ash/right/signed)
  (:translate %ash/right)
  (:policy :fast-safe)
  (:args (number :scs (signed-reg))
         (amount :scs (unsigned-reg)))
  (:arg-types signed-num unsigned-num)
  (:results (result :scs (signed-reg)))
  (:result-types signed-num)
  (:generator 4
    (store-reg result
      (load-reg number)
      (load-reg amount)
      (inst i32.shr_s))))

(define-vop (fast-%ash/right/fixnum)
  (:translate %ash/right)
  (:policy :fast-safe)
  (:args (number :scs (any-reg))
         (amount :scs (unsigned-reg)))
  (:arg-types tagged-num unsigned-num)
  (:results (result :scs (any-reg)))
  (:result-types tagged-num)
  (:generator 3
    (store-reg result
      (load-reg number)
      (load-reg amount)
      (inst i32.shr_s)
      (inst i32.const (lognot fixnum-tag-mask))
      (inst i32.and))))

(define-vop (signed-byte-32-len)
  (:translate integer-length)
  (:note "inline (signed-byte 32) integer-length")
  (:policy :fast-safe)
  (:args (arg :scs (signed-reg)))
  (:arg-types signed-num)
  (:results (res :scs (any-reg)))
  (:result-types positive-fixnum)
  (:generator 30
    ;; integer-length x = 32 - clz(x xor (x >> 31)), as a fixnum
    (store-reg res
      (inst i32.const n-word-bits)
      (load-reg arg)
      (load-reg arg)
      (inst i32.const (1- n-word-bits))
      (inst i32.shr_s)
      (inst i32.xor)
      (inst i32.clz)
      (inst i32.sub)
      (inst i32.const n-fixnum-tag-bits)
      (inst i32.shl))))

(define-vop (unsigned-byte-32-count)
  (:translate logcount)
  (:note "inline (unsigned-byte 32) logcount")
  (:policy :fast-safe)
  (:args (arg :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:results (res :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 30
    (store-reg res
      (load-reg arg)
      (inst i32.popcnt))))

;;;; Multiply and Divide.

(define-vop (fast-*/fixnum=>fixnum fast-fixnum-binop)
  (:args (x :scs (signed-reg)) ;; one operand needs to be untagged
         (y :scs (any-reg)))
  (:translate *)
  (:generator 2
    (store-reg r (load-reg x) (load-reg y) (inst i32.mul))))

(define-vop (fast-*/signed=>signed fast-signed-binop)
  (:translate *)
  (:generator 3
    (store-reg r (load-reg x) (load-reg y) (inst i32.mul))))

(define-vop (fast-*/unsigned=>unsigned fast-unsigned-binop)
  (:translate *)
  (:generator 3
    (store-reg r (load-reg x) (load-reg y) (inst i32.mul))))

;;; Division by zero traps in Wasm, so the check comes first.
(defun emit-division-by-zero-check (vop x y)
  (let ((zero (generate-error-code vop 'division-by-zero-error x)))
    (load-reg y)
    (inst i32.eqz)
    (inst jump-if zero)))

(define-vop (fast-truncate/fixnum fast-fixnum-binop)
  (:translate truncate)
  (:args (x :scs (any-reg) :to :save)
         (y :scs (any-reg) :to :save))
  (:results (q :scs (any-reg))
            (r :scs (any-reg)))
  (:result-types tagged-num tagged-num)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 11
    (emit-division-by-zero-check vop x y)
    (store-reg q
      (load-reg x)
      (load-reg y)
      (inst i32.div_s)
      (inst i32.const n-fixnum-tag-bits)
      (inst i32.shl))
    ;; the remainder of two fixnums is already a fixnum
    (store-reg r
      (load-reg x)
      (load-reg y)
      (inst i32.rem_s))))

(define-vop (fast-truncate/unsigned fast-unsigned-binop)
  (:translate truncate)
  (:args (x :scs (unsigned-reg) :to :save)
         (y :scs (unsigned-reg) :to :save))
  (:results (q :scs (unsigned-reg))
            (r :scs (unsigned-reg)))
  (:result-types unsigned-num unsigned-num)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 12
    (emit-division-by-zero-check vop x y)
    (store-reg q (load-reg x) (load-reg y) (inst i32.div_u))
    (store-reg r (load-reg x) (load-reg y) (inst i32.rem_u))))

(define-vop (fast-truncate/signed fast-signed-binop)
  (:translate truncate)
  (:args (x :scs (signed-reg) :to :save)
         (y :scs (signed-reg) :to :save))
  (:results (q :scs (signed-reg))
            (r :scs (signed-reg)))
  (:result-types signed-num signed-num)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 12
    (emit-division-by-zero-check vop x y)
    ;; i32.div_s traps on most-negative / -1; that quotient does not fit
    ;; the result type, so the compiler never selects this VOP for it.
    (store-reg q (load-reg x) (load-reg y) (inst i32.div_s))
    (store-reg r (load-reg x) (load-reg y) (inst i32.rem_s))))

;;;; Binary conditional VOPs.

(define-vop (fast-conditional)
  (:conditional)
  (:variant-vars condition)
  (:info target not-p)
  (:policy :fast-safe))

(defun emit-fast-conditional (x y condition signedness target not-p)
  (load-reg x)
  (load-reg y)
  (emit-compare (if (eq signedness :unsigned)
                    (ecase condition (:lt :ltu) (:gt :gtu) (:eq :eq))
                    condition))
  (emit-conditional-branch target not-p))

(define-vop (fast-conditional/fixnum fast-conditional)
  (:args (x :scs (any-reg))
         (y :scs (any-reg)))
  (:arg-types tagged-num tagged-num)
  (:note "inline fixnum comparison")
  (:generator 1
    (emit-fast-conditional x y condition :signed target not-p)))

(define-vop (fast-conditional/signed fast-conditional)
  (:args (x :scs (signed-reg))
         (y :scs (signed-reg)))
  (:arg-types signed-num signed-num)
  (:note "inline (signed-byte 32) comparison")
  (:generator 1
    (emit-fast-conditional x y condition :signed target not-p)))

(define-vop (fast-conditional/unsigned fast-conditional)
  (:args (x :scs (unsigned-reg))
         (y :scs (unsigned-reg)))
  (:arg-types unsigned-num unsigned-num)
  (:note "inline (unsigned-byte 32) comparison")
  (:generator 1
    (emit-fast-conditional x y condition :unsigned target not-p)))

(defmacro define-conditional-vop (translate op)
  `(progn
     ,@(mapcar (lambda (suffix)
                 (unless (and (eq suffix '/fixnum)
                              (eq translate 'eql))
                   `(define-vop (,(intern (format nil "~:@(FAST-IF-~A~A~)"
                                                  translate suffix))
                                 ,(intern
                                   (format nil "~:@(FAST-CONDITIONAL~A~)"
                                           suffix)))
                      (:translate ,translate)
                      (:variant ,op))))
               '(/fixnum /signed /unsigned))))

(define-conditional-vop < :lt)
(define-conditional-vop > :gt)
(define-conditional-vop eql :eq)

;;; EQL/FIXNUM is funny because the first arg can be of any type, not just a
;;; known fixnum.

;;; These versions specify a fixnum restriction on their first arg.
;;; We have also generic-eql/fixnum VOPs which are the same, but have
;;; no restriction on the first arg and a higher cost.  The reason for
;;; doing this is to prevent fixnum specific operations from being
;;; used on word integers, spuriously consing the argument.
(define-vop (fast-eql/fixnum fast-conditional)
  (:args (x :scs (any-reg))
         (y :scs (any-reg)))
  (:arg-types tagged-num tagged-num)
  (:note "inline fixnum comparison")
  (:translate eql)
  (:ignore condition)
  (:generator 1
    (emit-fast-conditional x y :eq :signed target not-p)))

(define-vop (generic-eql/fixnum fast-eql/fixnum)
  (:args (x :scs (any-reg descriptor-reg))
         (y :scs (any-reg)))
  (:arg-types * tagged-num)
  (:variant-cost 7))

;;;; Logical operations

(macrolet ((define (translate operation)
             `(define-vop ()
                (:translate ,translate)
                (:note ,(string translate))
                (:policy :fast-safe)
                (:args (num :scs (unsigned-reg))
                       (amount :scs (signed-reg)))
                (:arg-types unsigned-num tagged-num)
                (:results (r :scs (unsigned-reg)))
                (:result-types unsigned-num)
                (:generator 1
                  (store-reg r
                    (load-reg num)
                    (load-reg amount)
                    (inst ,operation))))))
  (define shift-towards-start i32.shr_u)
  (define shift-towards-end   i32.shl))

;;;; Modular arithmetic
;;;;
;;;; i32 arithmetic is arithmetic modulo 2^32, so the modular VOPs are
;;;; the unsigned VOPs under another translation.

(defmacro define-mod-binop ((name prototype) function)
  `(define-vop (,name ,prototype)
     (:args (x :scs (unsigned-reg signed-reg))
            (y :scs (unsigned-reg signed-reg)))
     (:arg-types untagged-num untagged-num)
     (:results (r :scs (unsigned-reg signed-reg)))
     (:result-types unsigned-num)
     (:translate ,function)))

(defmacro define-mod-binop-c ((name prototype) function)
  `(define-vop (,name ,prototype)
     (:args (x :scs (unsigned-reg signed-reg)))
     (:info y)
     (:arg-types untagged-num (:constant short-immediate))
     (:results (r :scs (unsigned-reg signed-reg)))
     (:result-types unsigned-num)
     (:translate ,function)))

(macrolet ((def (name -c-p)
             (let ((funmod   (symbolicate name "-MOD32"))
                   (funfx    (symbolicate name "-MODFX"))
                   (vopu     (symbolicate "FAST-" name "/UNSIGNED=>UNSIGNED"))
                   (vopcu    (symbolicate "FAST-" name "-C/UNSIGNED=>UNSIGNED"))
                   (vopf     (symbolicate "FAST-" name "/FIXNUM=>FIXNUM"))
                   (vopcf    (symbolicate "FAST-" name "-C/FIXNUM=>FIXNUM"))
                   (vopmodu  (symbolicate "FAST-" name "-MOD32/WORD=>UNSIGNED"))
                   (vopmodf  (symbolicate "FAST-" name "-MOD32/FIXNUM=>FIXNUM"))
                   (vopmodcu (symbolicate "FAST-" name "-MOD32-C/WORD=>UNSIGNED"))
                   (vopfxf   (symbolicate "FAST-" name "-MODFX/FIXNUM=>FIXNUM"))
                   (vopfxcf  (symbolicate "FAST-" name "-MODFX-C/FIXNUM=>FIXNUM")))
               `(progn
                  (define-modular-fun ,funmod (x y) ,name :untagged nil ,n-word-bits)
                  (define-modular-fun ,funfx (x y) ,name :tagged t
                                      ,(- n-word-bits n-fixnum-tag-bits))
                  (define-mod-binop (,vopmodu ,vopu) ,funmod)
                  (define-vop (,vopmodf ,vopf) (:translate ,funmod))
                  (define-vop (,vopfxf ,vopf) (:translate ,funfx))
                  ,@(when -c-p
                      `((define-mod-binop-c (,vopmodcu ,vopcu) ,funmod)
                        (define-vop (,vopfxcf ,vopcf) (:translate ,funfx))))))))
  (def + t)
  (def - t)
  (def * nil))

(define-vop (fast-ash-left-mod32-c/unsigned=>unsigned
             fast-ash-c/unsigned=>unsigned)
  (:translate ash-left-mod32))

(define-vop (fast-ash-left-mod32/unsigned=>unsigned
             fast-ash-left/unsigned=>unsigned))

(deftransform ash-left-mod32 ((integer count)
                              ((unsigned-byte 32) (unsigned-byte 5)))
  (when (sb-c:constant-lvar-p count)
    (sb-c::give-up-ir1-transform))
  '(%primitive fast-ash-left-mod32/unsigned=>unsigned integer count))

(define-modular-fun lognot-mod32 (x) lognot :untagged nil 32)

(define-vop (lognot-mod32/unsigned=>unsigned)
  (:translate lognot-mod32)
  (:args (x :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:results (r :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:policy :fast-safe)
  (:generator 1
    (store-reg r
      (load-reg x)
      (inst i32.const -1)
      (inst i32.xor))))

;;;; Bignum stuff.
;;;;
;;;; Double-word intermediate results are computed in i64.

(define-vop (bignum-length)
  (:translate sb-bignum:%bignum-length)
  (:policy :fast-safe)
  (:args (x :scs (descriptor-reg)))
  (:results (res :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 6
    (store-reg res
      (load-reg x)
      (emit-load-word (- other-pointer-lowtag))
      (inst i32.const n-widetag-bits)
      (inst i32.shr_u))))

(define-vop (bignum-set-length)
  (:translate sb-bignum:%bignum-set-length)
  (:policy :fast-safe)
  (:args (x :scs (descriptor-reg))
         (data :scs (any-reg immediate)))
  (:arg-types * positive-fixnum)
  (:generator 6
    (load-reg x)
    (emit-store-word (- other-pointer-lowtag)
      (load-reg x)
      (emit-load-word (- other-pointer-lowtag))
      (inst i32.const widetag-mask)
      (inst i32.and)
      (sc-case data
        (any-reg
         (load-reg data)
         (inst i32.const (- n-widetag-bits n-fixnum-tag-bits))
         (inst i32.shl))
        (immediate
         (inst i32.const (ash (tn-value data) n-widetag-bits))))
      (inst i32.or))))

(define-full-reffer bignum-ref * bignum-digits-offset other-pointer-lowtag
  (unsigned-reg) unsigned-num sb-bignum:%bignum-ref)

(define-full-setter bignum-set * bignum-digits-offset other-pointer-lowtag
  (unsigned-reg) unsigned-num sb-bignum:%bignum-set)

(define-vop (digit-0-or-plus)
  (:translate sb-bignum:%digit-0-or-plusp)
  (:policy :fast-safe)
  (:args (digit :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:conditional)
  (:info target not-p)
  (:generator 1
    (load-reg digit)
    (inst i32.const 0)
    (inst i32.ge_s)
    (emit-conditional-branch target not-p)))

;;; Push the i64 sum a + b + (c >> n-fixnum-tag-bits).
(defun emit-add-with-carry (a b c)
  (load-reg a)
  (inst i64.extend_i32_u)
  (load-reg b)
  (inst i64.extend_i32_u)
  (inst i64.add)
  (load-reg c)
  (inst i32.const n-fixnum-tag-bits)
  (inst i32.shr_u)
  (inst i64.extend_i32_u)
  (inst i64.add))

(define-vop (add-w/carry)
  (:translate sb-bignum:%add-with-carry)
  (:policy :fast-safe)
  (:args (a :scs (unsigned-reg) :to :save)
         (b :scs (unsigned-reg) :to :save)
         (c :scs (any-reg) :to :save))
  (:arg-types unsigned-num unsigned-num positive-fixnum)
  (:results (result :scs (unsigned-reg))
            (carry :scs (unsigned-reg)))
  (:result-types unsigned-num positive-fixnum)
  (:generator 5
    (store-reg carry
      (emit-add-with-carry a b c)
      (inst i64.const 32)
      (inst i64.shr_u)
      (inst i32.wrap_i64))
    (store-reg result
      (emit-add-with-carry a b c)
      (inst i32.wrap_i64))))

;;; Push the i64 difference a - b - (1 - (c >> n-fixnum-tag-bits)).
(defun emit-subtract-with-borrow (a b c)
  (load-reg a)
  (inst i64.extend_i32_u)
  (load-reg b)
  (inst i64.extend_i32_u)
  (inst i64.sub)
  (inst i64.const 1)
  (inst i64.sub)
  (load-reg c)
  (inst i32.const n-fixnum-tag-bits)
  (inst i32.shr_u)
  (inst i64.extend_i32_u)
  (inst i64.add))

(define-vop (sub-w/borrow)
  (:translate sb-bignum:%subtract-with-borrow)
  (:policy :fast-safe)
  (:args (a :scs (unsigned-reg) :to :save)
         (b :scs (unsigned-reg) :to :save)
         (c :scs (any-reg) :to :save))
  (:arg-types unsigned-num unsigned-num positive-fixnum)
  (:results (result :scs (unsigned-reg))
            (borrow :scs (unsigned-reg)))
  (:result-types unsigned-num positive-fixnum)
  (:generator 4
    ;; borrow out is 1 when no borrow happened (the difference is >= 0)
    (store-reg borrow
      (emit-subtract-with-borrow a b c)
      (inst i64.const 0)
      (inst i64.ge_s))
    (store-reg result
      (emit-subtract-with-borrow a b c)
      (inst i32.wrap_i64))))

;;; Push the i64 product x * y (unsigned).
(defun emit-unsigned-multiply (x y)
  (load-reg x)
  (inst i64.extend_i32_u)
  (load-reg y)
  (inst i64.extend_i32_u)
  (inst i64.mul))

(defun emit-add-unsigned-word (tn)
  (load-reg tn)
  (inst i64.extend_i32_u)
  (inst i64.add))

(defun emit-high-word ()
  (inst i64.const 32)
  (inst i64.shr_u)
  (inst i32.wrap_i64))

(define-vop (bignum-mult-and-add-3-arg)
  (:translate sb-bignum:%multiply-and-add)
  (:policy :fast-safe)
  (:args (x :scs (unsigned-reg) :to :save)
         (y :scs (unsigned-reg) :to :save)
         (carry-in :scs (unsigned-reg) :to :save))
  (:arg-types unsigned-num unsigned-num unsigned-num)
  (:results (hi :scs (unsigned-reg))
            (lo :scs (unsigned-reg)))
  (:result-types unsigned-num unsigned-num)
  (:generator 4
    (store-reg hi
      (emit-unsigned-multiply x y)
      (emit-add-unsigned-word carry-in)
      (emit-high-word))
    (store-reg lo
      (emit-unsigned-multiply x y)
      (emit-add-unsigned-word carry-in)
      (inst i32.wrap_i64))))

(define-vop (bignum-mult-and-add-4-arg)
  (:translate sb-bignum:%multiply-and-add)
  (:policy :fast-safe)
  (:args (x :scs (unsigned-reg) :to :save)
         (y :scs (unsigned-reg) :to :save)
         (prev :scs (unsigned-reg) :to :save)
         (carry-in :scs (unsigned-reg) :to :save))
  (:arg-types unsigned-num unsigned-num unsigned-num unsigned-num)
  (:results (hi :scs (unsigned-reg))
            (lo :scs (unsigned-reg)))
  (:result-types unsigned-num unsigned-num)
  (:generator 8
    (store-reg hi
      (emit-unsigned-multiply x y)
      (emit-add-unsigned-word prev)
      (emit-add-unsigned-word carry-in)
      (emit-high-word))
    (store-reg lo
      (emit-unsigned-multiply x y)
      (emit-add-unsigned-word prev)
      (emit-add-unsigned-word carry-in)
      (inst i32.wrap_i64))))

(define-vop (bignum-mult)
  (:translate sb-bignum:%multiply)
  (:policy :fast-safe)
  (:args (x :scs (unsigned-reg) :to :save)
         (y :scs (unsigned-reg) :to :save))
  (:arg-types unsigned-num unsigned-num)
  (:results (hi :scs (unsigned-reg))
            (lo :scs (unsigned-reg)))
  (:result-types unsigned-num unsigned-num)
  (:generator 1
    (store-reg hi
      (emit-unsigned-multiply x y)
      (emit-high-word))
    (store-reg lo
      (emit-unsigned-multiply x y)
      (inst i32.wrap_i64))))

(define-vop (mulhi)
  (:translate %multiply-high)
  (:policy :fast-safe)
  (:args (x :scs (unsigned-reg))
         (y :scs (unsigned-reg)))
  (:arg-types unsigned-num unsigned-num)
  (:results (hi :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:generator 1
    (store-reg hi
      (emit-unsigned-multiply x y)
      (emit-high-word))))

(define-vop (mulhi/fx)
  (:translate %multiply-high)
  (:policy :fast-safe)
  (:args (x :scs (any-reg))
         (y :scs (unsigned-reg)))
  (:arg-types positive-fixnum unsigned-num)
  (:results (hi :scs (any-reg)))
  (:result-types positive-fixnum)
  (:generator 15
    (store-reg hi
      (emit-unsigned-multiply x y)
      (emit-high-word)
      (inst i32.const (lognot fixnum-tag-mask))
      (inst i32.and))))

;;; Push the i64 (num-high << 32) | num-low.
(defun emit-double-word (num-high num-low)
  (load-reg num-high)
  (inst i64.extend_i32_u)
  (inst i64.const 32)
  (inst i64.shl)
  (load-reg num-low)
  (inst i64.extend_i32_u)
  (inst i64.or))

(define-vop (bignum-floor)
  (:translate sb-bignum:%bigfloor)
  (:policy :fast-safe)
  (:args (num-high :scs (unsigned-reg) :to :save)
         (num-low :scs (unsigned-reg) :to :save)
         (denom :scs (unsigned-reg) :to :save))
  (:arg-types unsigned-num unsigned-num unsigned-num)
  (:results (quo :scs (unsigned-reg))
            (rem :scs (unsigned-reg)))
  (:result-types unsigned-num unsigned-num)
  (:generator 10
    ;; num-high < denom, so the quotient fits a word
    (store-reg quo
      (emit-double-word num-high num-low)
      (load-reg denom)
      (inst i64.extend_i32_u)
      (inst i64.div_u)
      (inst i32.wrap_i64))
    (store-reg rem
      (emit-double-word num-high num-low)
      (load-reg denom)
      (inst i64.extend_i32_u)
      (inst i64.rem_u)
      (inst i32.wrap_i64))))

(define-vop (signify-digit)
  (:translate sb-bignum:%fixnum-digit-with-correct-sign)
  (:policy :fast-safe)
  (:args (digit :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:results (res :scs (any-reg signed-reg)))
  (:result-types signed-num)
  (:generator 1
    (sc-case res
      (any-reg
       (store-reg res
         (load-reg digit)
         (inst i32.const n-fixnum-tag-bits)
         (inst i32.shl)))
      (signed-reg
       (move res digit)))))

(define-vop (digit-ashr)
  (:translate sb-bignum:%ashr)
  (:policy :fast-safe)
  (:args (digit :scs (unsigned-reg))
         (count :scs (unsigned-reg)))
  (:arg-types unsigned-num positive-fixnum)
  (:results (result :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:generator 1
    (store-reg result
      (load-reg digit)
      (load-reg count)
      (inst i32.shr_s))))

(define-vop (digit-lshr digit-ashr)
  (:translate sb-bignum:%digit-logical-shift-right)
  (:generator 1
    (store-reg result
      (load-reg digit)
      (load-reg count)
      (inst i32.shr_u))))

(define-vop (digit-ashl digit-ashr)
  (:translate sb-bignum:%ashl)
  (:generator 1
    (store-reg result
      (load-reg digit)
      (load-reg count)
      (inst i32.shl))))

;;;; FASTREM-32: the remainder of a division by a constant through a
;;;; precomputed coefficient C (SB-C:COMPUTE-FASTREM-COEFFICIENT):
;;;; (ldb (byte 32 32) (* (ldb (byte 32 0) (* dividend c)) divisor)).
(define-vop (fastrem-32)
  (:translate fastrem-32)
  (:policy :fast-safe)
  (:args (dividend :scs (unsigned-reg))
         (c :scs (unsigned-reg))
         (divisor :scs (unsigned-reg)))
  (:arg-types unsigned-num unsigned-num unsigned-num)
  (:results (remainder :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:generator 10
    (store-reg remainder
      (load-reg dividend)
      (load-reg c)
      (inst i32.mul)
      (inst i64.extend_i32_u)
      (load-reg divisor)
      (inst i64.extend_i32_u)
      (inst i64.mul)
      (inst i64.const 32)
      (inst i64.shr_u)
      (inst i32.wrap_i64))))
