;;;; WebAssembly VM definitions of various system hacking operations

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Type frobbing VOPs

(define-vop (descriptor-hash32)
  (:translate descriptor-hash32)
  (:args (arg :scs (any-reg descriptor-reg)))
  (:results (res :scs (any-reg)))
  (:result-types positive-fixnum)
  (:policy :fast-safe)
  (:generator 1
    ;; clear the tag bits and the sign bit: 29 bits of precision
    (store-reg res
      (load-reg arg)
      (inst i32.const (lognot fixnum-tag-mask))
      (inst i32.and)
      (inst i32.const 1)
      (inst i32.shl)
      (inst i32.const 1)
      (inst i32.shr_u))))

(define-vop (widetag-of)
  (:translate widetag-of)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :to :save))
  (:results (result :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 6
    (let ((done (gen-label)))
      ;; First, pick off the immediate types, starting with FIXNUM.
      (store-reg result
        (load-reg object)
        (inst i32.const fixnum-tag-mask)
        (inst i32.and))
      (load-reg result)
      (inst i32.eqz)
      (inst jump-if done)
      ;; If it wasn't a fixnum, start with the full widetag. That is the
      ;; answer for an immediate; a pointer (low bit set) needs more work.
      (store-reg result
        (load-reg object)
        (inst i32.const widetag-mask)
        (inst i32.and))
      (load-reg object)
      (inst i32.const #b1)
      (inst i32.and)
      (inst i32.eqz)
      (inst jump-if done)
      ;; For lists and instances the lowtag is the answer; function and
      ;; other pointers (bit 2 set) carry the widetag in the header.
      (store-reg result
        (load-reg object)
        (inst i32.const lowtag-mask)
        (inst i32.and))
      (load-reg object)
      (inst i32.const #b100)
      (inst i32.and)
      (inst i32.eqz)
      (inst jump-if done)
      (store-reg result
        (load-reg object)
        (load-reg result)
        (inst i32.sub)
        (inst i32.load8_u 0))
      (emit-label done))))

(define-vop ()
  (:translate sb-c::%structure-is-a)
  (:args (x :scs (descriptor-reg)))
  (:arg-types * (:constant t))
  (:policy :fast-safe)
  (:conditional)
  ;; "extra" info in conditional vops follows the 2 super-magical info args
  (:info target not-p test-layout)
  (:generator 4
    (load-reg x)
    (emit-load-sized 4 nil (layout-id-offset test-layout))
    (inst i32.const (ensure-layout-id-fixup-or-imm test-layout))
    (if not-p (inst i32.ne) (inst i32.eq))
    (inst jump-if target)))

(define-vop (%other-pointer-widetag)
  (:translate %other-pointer-widetag)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg)))
  (:results (result :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 6
    (store-reg result
      (load-reg object)
      (emit-load-sized 1 nil (- other-pointer-lowtag)))))

(define-vop ()
  (:translate %fun-pointer-widetag)
  (:policy :fast-safe)
  (:args (function :scs (descriptor-reg)))
  (:results (result :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 6
    (store-reg result
      (load-reg function)
      (emit-load-sized 1 nil (- fun-pointer-lowtag)))))

(define-vop (get-header-data)
  (:translate get-header-data)
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

(define-vop (set-header-data)
  (:translate set-header-data)
  (:policy :fast-safe)
  (:args (x :scs (descriptor-reg))
         (data :scs (any-reg immediate)))
  (:arg-types * positive-fixnum)
  (:generator 6
    (load-reg x)
    (emit-store-word (- other-pointer-lowtag)
      (load-reg x)
      (emit-load-sized 1 nil (- other-pointer-lowtag))
      (sc-case data
        (any-reg
         (load-reg data)
         (inst i32.const (- n-widetag-bits n-fixnum-tag-bits))
         (inst i32.shl))
        (immediate
         (inst i32.const (ash (tn-value data) n-widetag-bits))))
      (inst i32.or))))

;;;; Stack pointers

(define-vop (binding-stack-pointer-sap)
  (:results (int :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:translate binding-stack-pointer-sap)
  (:policy :fast-safe)
  (:generator 1
    (load-binding-stack-pointer int)))

(define-vop (control-stack-pointer-sap)
  (:results (int :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:translate control-stack-pointer-sap)
  (:policy :fast-safe)
  (:generator 1
    (move int csp-tn)))

(define-vop ()
  (:translate current-sp)
  (:policy :fast-safe)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 1
    (move res csp-tn)))

(define-vop ()
  (:translate stack-ref)
  (:policy :fast-safe)
  (:args (object :scs (sap-reg))
         (offset :scs (any-reg)))
  (:arg-types system-area-pointer positive-fixnum)
  (:results (result :scs (descriptor-reg)))
  (:result-types *)
  (:generator 5
    (store-reg result
      (load-reg object)
      (load-reg offset)
      (inst i32.add)
      (inst i32.load 0))))

(define-vop ()
  (:translate %set-stack-ref)
  (:policy :fast-safe)
  (:args (object :scs (sap-reg))
         (offset :scs (any-reg))
         (value :scs (descriptor-reg)))
  (:arg-types system-area-pointer positive-fixnum *)
  (:generator 2
    (load-reg object)
    (load-reg offset)
    (inst i32.add)
    (load-reg value)
    (inst i32.store 0)))

;;;; Code object frobbing.

(define-vop (code-instructions)
  (:translate code-instructions)
  (:policy :fast-safe)
  (:args (code :scs (descriptor-reg)))
  (:results (sap :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 10
    (store-reg sap
      (load-reg code)
      (load-reg code)
      (emit-load-word (- (* n-word-bytes code-boxed-size-slot) other-pointer-lowtag))
      (inst i32.add)
      (inst i32.const other-pointer-lowtag)
      (inst i32.sub))))

(eval-when (:compile-toplevel)
  (aver (not (logtest code-header-widetag #b11000000))))

(define-vop (code-trailer-ref)
  (:translate code-trailer-ref)
  (:policy :fast-safe)
  (:args (code :scs (descriptor-reg))
         (offset :scs (signed-reg)))
  (:arg-types * fixnum)
  (:results (res :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:generator 10
    (store-reg res
      (load-reg code)
      ;; boxed header size in bytes: shift out the GC bits, then the
      ;; widetag; the byte conversion cancels against the extra shift.
      (load-reg code)
      (emit-load-word (- other-pointer-lowtag))
      (inst i32.const 2)
      (inst i32.shl)
      (inst i32.const n-widetag-bits)
      (inst i32.shr_u)
      (inst i32.add)
      (load-reg offset)
      (inst i32.add)
      (emit-load-word (- other-pointer-lowtag)))))

(define-vop (compute-fun)
  (:args (code :scs (descriptor-reg))
         (offset :scs (signed-reg unsigned-reg)))
  (:arg-types * positive-fixnum)
  (:results (func :scs (descriptor-reg)))
  (:generator 10
    (store-reg func
      (load-reg code)
      (load-reg code)
      (emit-load-word (- (* n-word-bytes code-boxed-size-slot) other-pointer-lowtag))
      (inst i32.add)
      (load-reg offset)
      (inst i32.add)
      (inst i32.const (- other-pointer-lowtag fun-pointer-lowtag))
      (inst i32.sub))))

(define-vop (code-header-ref)
  (:translate code-header-ref)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg)))
  (:arg-types * tagged-num)
  (:results (value :scs (descriptor-reg any-reg)))
  (:result-types *)
  (:generator 5
    (store-reg value
      (emit-indexed-address object index n-word-bytes)
      (emit-load-word (- other-pointer-lowtag)))))

(define-vop (code-header-ref-c)
  (:translate code-header-ref)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg)))
  (:info index)
  (:arg-types * (:constant (load/store-index #.n-word-bytes 7 0)))
  (:results (value :scs (descriptor-reg any-reg)))
  (:result-types *)
  (:generator 4
    (loadw value object index other-pointer-lowtag)))

(define-vop (code-header-set)
  (:translate code-header-set)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg))
         (index :scs (any-reg))
         (value :scs (any-reg descriptor-reg)))
  (:arg-types * tagged-num *)
  (:generator 10
    (emit-gengc-barrier object t
                        (lambda ()
                          (emit-indexed-address object index n-word-bytes)
                          (inst i32.const (- other-pointer-lowtag))
                          (inst i32.add)))
    ;; set the "written" flag of the code header (OBJ_WRITTEN_FLAG, code.h):
    ;; the collector scans the boxed words of an old code object only when
    ;; the flag says they were written since the object was created
    (load-reg object)
    (inst i32.const (- 3 other-pointer-lowtag))
    (inst i32.add)
    (load-reg object)
    (emit-load-sized 1 nil (- 3 other-pointer-lowtag))
    (inst i32.const #x40)
    (inst i32.or)
    (inst i32.store8 0)
    (emit-indexed-address object index n-word-bytes)
    (emit-store-word (- other-pointer-lowtag)
      (load-reg value))))

(define-full-reffer %weakvec-ref * vector-data-offset other-pointer-lowtag
  (any-reg descriptor-reg) * %weakvec-ref)
(define-full-setter %weakvec-set * vector-data-offset other-pointer-lowtag
  (any-reg descriptor-reg) * %weakvec-set)

;;;; Interrupts, halting, barriers

(defknown sb-unix::receive-pending-interrupt () (values))
(define-vop (sb-unix::receive-pending-interrupt)
  (:policy :fast-safe)
  (:translate sb-unix::receive-pending-interrupt)
  (:generator 1
    (inst call +import-pending-interrupt+)))

(define-vop (do-pending-interrupt)
  (:generator 247
    (inst call +import-pending-interrupt+)))

(define-vop (halt)
  (:generator 1
    (inst unreachable)))

(define-vop ()
  (:translate spin-loop-hint)
  (:policy :fast-safe)
  (:generator 0))

;;; Barriers: a single thread of Wasm execution sees its own stores in
;;; order, so the barriers are no-ops.
(define-vop (%compiler-barrier)
  (:policy :fast-safe)
  (:translate %compiler-barrier)
  (:generator 3))

(define-vop (%memory-barrier)
  (:policy :fast-safe)
  (:translate %memory-barrier)
  (:generator 3))

(define-vop (%read-barrier)
  (:policy :fast-safe)
  (:translate %read-barrier)
  (:generator 3))

(define-vop (%write-barrier)
  (:policy :fast-safe)
  (:translate %write-barrier)
  (:generator 3))

(define-vop (%data-dependency-barrier)
  (:policy :fast-safe)
  (:translate %data-dependency-barrier)
  (:generator 3))

;;; Coverage marks live in a byte area of the code object whose position
;;; is only known once the boxed header length is; the mark is a load-time
;;; fixup on the code object (sb-cover support is Phase 4 of the plan).
(define-vop (sb-c::mark-covered)
  (:info index)
  (:generator 4
    (load-reg code-tn)
    (inst i32.const (make-fixup index :code-coverage-index))
    (inst i32.add)
    (inst i32.const 1)
    (inst i32.store8 0)))

;;;; Square root

(define-vop (%sqrtf)
  (:translate %sqrtf)
  (:policy :fast-safe)
  (:args (x :scs (single-reg)))
  (:arg-types single-float)
  (:results (y :scs (single-reg)))
  (:result-types single-float)
  (:generator 1
    (store-freg y :single
      (load-freg x :single)
      (inst f32.sqrt))))

(define-vop (%sqrt)
  (:translate %sqrt)
  (:policy :fast-safe)
  (:args (x :scs (double-reg)))
  (:arg-types double-float)
  (:results (y :scs (double-reg)))
  (:result-types double-float)
  (:generator 1
    (store-freg y :double
      (load-freg x :double)
      (inst f64.sqrt))))
