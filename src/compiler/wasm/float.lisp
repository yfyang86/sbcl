;;;; floating point support for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Move functions between float registers and the number stack.

(define-move-fun (load-single 1) (vop x y)
  ((single-stack) (single-reg))
  (store-freg y :single
    (load-reg (current-nfp-tn vop))
    (inst f32.load (tn-byte-offset x))))

(define-move-fun (store-single 1) (vop x y)
  ((single-reg) (single-stack))
  (load-reg (current-nfp-tn vop))
  (load-freg x :single)
  (inst f32.store (tn-byte-offset y)))

(define-move-fun (load-double 2) (vop x y)
  ((double-stack) (double-reg))
  (store-freg y :double
    (load-reg (current-nfp-tn vop))
    (inst f64.load (tn-byte-offset x))))

(define-move-fun (store-double 2) (vop x y)
  ((double-reg) (double-stack))
  (load-reg (current-nfp-tn vop))
  (load-freg x :double)
  (inst f64.store (tn-byte-offset y)))

;;;; Float register moves.

(macrolet ((frob (vop sc format)
             `(progn
                (define-vop (,vop)
                  (:args (x :scs (,sc)
                            :target y
                            :load-if (not (location= x y))))
                  (:results (y :scs (,sc)
                               :load-if (not (location= x y))))
                  (:note "float move")
                  (:generator 0
                    (unless (location= y x)
                      (store-freg y ,format (load-freg x ,format)))))
                (define-move-vop ,vop :move (,sc) (,sc)))))
  (frob single-move single-reg :single)
  (frob double-move double-reg :double))

;;; Move from a float to a descriptor: allocate a boxed float.
(define-vop (move-from-float)
  (:args (x :to :save))
  (:results (y))
  (:note "float to pointer coercion")
  (:variant-vars fmt size type data)
  (:generator 13
    (with-fixed-allocation (y type size)
      (load-reg y)
      (emit-store-float fmt (- (* data n-word-bytes) other-pointer-lowtag)
        (load-freg x fmt)))))

(macrolet ((frob (name sc &rest args)
             `(progn
                (define-vop (,name move-from-float)
                  (:args (x :scs (,sc) :to :save))
                  (:results (y :scs (descriptor-reg)))
                  (:variant ,@args))
                (define-move-vop ,name :move (,sc) (descriptor-reg)))))
  (frob move-from-single single-reg
        :single single-float-size single-float-widetag single-float-value-slot)
  (frob move-from-double double-reg
        :double double-float-size double-float-widetag double-float-value-slot))

;;; Move from a descriptor to a float register.
(macrolet ((frob (name sc fmt value)
             `(progn
                (define-vop (,name)
                  (:args (x :scs (descriptor-reg)))
                  (:results (y :scs (,sc)))
                  (:note "pointer to float coercion")
                  (:generator 2
                    (store-freg y ,fmt
                      (load-reg x)
                      (emit-load-float ,fmt (- (* ,value n-word-bytes) other-pointer-lowtag)))))
                (define-move-vop ,name :move (descriptor-reg) (,sc)))))
  (frob move-to-single single-reg :single single-float-value-slot)
  (frob move-to-double double-reg :double double-float-value-slot))

;;; Move from a float register to a float argument passing location.
(macrolet ((frob (name sc stack-sc format)
             `(progn
                (define-vop (,name)
                  (:args (x :scs (,sc) :target y)
                         (nfp :scs (any-reg)
                              :load-if (not (sc-is y ,sc))))
                  (:results (y))
                  (:note "float arg move")
                  (:generator 1
                    (sc-case y
                      (,sc
                       (unless (location= x y)
                         (store-freg y ,format (load-freg x ,format))))
                      (,stack-sc
                       (load-reg nfp)
                       (emit-store-float ,format (tn-byte-offset y)
                         (load-freg x ,format))))))
                (define-move-vop ,name :move-arg
                  (,sc descriptor-reg) (,sc)))))
  (frob move-single-float-arg single-reg single-stack :single)
  (frob move-double-float-arg double-reg double-stack :double))

;;;; Complex float move functions
;;;;
;;;; Complex floats are two consecutive float registers and two
;;;; consecutive stack entries of the component size.

(macrolet ((define-complex-moves (format size stack-sc reg-sc load-name store-name cost)
             `(progn
                (define-move-fun (,load-name ,cost) (vop x y)
                  ((,stack-sc) (,reg-sc))
                  (let ((offset (tn-byte-offset x)))
                    (store-freg-slot (complex-reg-real-offset y) ,format
                      (load-reg (current-nfp-tn vop))
                      (emit-load-float ,format offset))
                    (store-freg-slot (complex-reg-imag-offset y) ,format
                      (load-reg (current-nfp-tn vop))
                      (emit-load-float ,format (+ offset ,size)))))
                (define-move-fun (,store-name ,cost) (vop x y)
                  ((,reg-sc) (,stack-sc))
                  (let ((offset (tn-byte-offset y)))
                    (load-reg (current-nfp-tn vop))
                    (emit-store-float ,format offset
                      (load-freg-slot (complex-reg-real-offset x) ,format))
                    (load-reg (current-nfp-tn vop))
                    (emit-store-float ,format (+ offset ,size)
                      (load-freg-slot (complex-reg-imag-offset x) ,format)))))))
  (define-complex-moves :single 4 complex-single-stack complex-single-reg
    load-complex-single store-complex-single 2)
  (define-complex-moves :double 8 complex-double-stack complex-double-reg
    load-complex-double store-complex-double 2))

;;; Copy complex float Y from X.
(defun move-complex (format y x)
  (unless (location= x y)
    (store-freg-slot (complex-reg-real-offset y) format
      (load-freg-slot (complex-reg-real-offset x) format))
    (store-freg-slot (complex-reg-imag-offset y) format
      (load-freg-slot (complex-reg-imag-offset x) format))))

(define-vop (complex-single-move)
  (:args (x :scs (complex-single-reg) :target y
            :load-if (not (location= x y))))
  (:results (y :scs (complex-single-reg) :load-if (not (location= x y))))
  (:note "complex single float move")
  (:generator 0
    (move-complex :single y x)))
(define-move-vop complex-single-move :move
  (complex-single-reg) (complex-single-reg))

(define-vop (complex-double-move)
  (:args (x :scs (complex-double-reg)
            :target y :load-if (not (location= x y))))
  (:results (y :scs (complex-double-reg) :load-if (not (location= x y))))
  (:note "complex double float move")
  (:generator 0
    (move-complex :double y x)))
(define-move-vop complex-double-move :move
  (complex-double-reg) (complex-double-reg))

;;; Move from a complex float to a descriptor reg. Allocate a new
;;; complex float object in the process.
(define-vop (move-from-complex-float)
  (:args (x))
  (:results (y :scs (descriptor-reg)))
  (:variant-vars format real-slot imag-slot widetag size)
  (:generator 13
    (with-fixed-allocation (y widetag size)
      (load-reg y)
      (emit-store-float format (- (* real-slot n-word-bytes) other-pointer-lowtag)
        (load-freg-slot (complex-reg-real-offset x) format))
      (load-reg y)
      (emit-store-float format (- (* imag-slot n-word-bytes) other-pointer-lowtag)
        (load-freg-slot (complex-reg-imag-offset x) format)))))

(define-vop (move-from-complex-single move-from-complex-float)
  (:args (x :scs (complex-single-reg) :to :save))
  (:note "complex single float to pointer coercion")
  (:variant :single complex-single-float-real-slot complex-single-float-imag-slot
            complex-single-float-widetag complex-single-float-size))
(define-move-vop move-from-complex-single :move
  (complex-single-reg) (descriptor-reg))

(define-vop (move-from-complex-double move-from-complex-float)
  (:args (x :scs (complex-double-reg) :to :save))
  (:note "complex double float to pointer coercion")
  (:variant :double complex-double-float-real-slot complex-double-float-imag-slot
            complex-double-float-widetag complex-double-float-size))
(define-move-vop move-from-complex-double :move
  (complex-double-reg) (descriptor-reg))

;;; Move from a descriptor to a complex float register.
(define-vop (move-to-complex-float)
  (:args (x :scs (descriptor-reg)))
  (:results (y))
  (:note "pointer to complex float coercion")
  (:variant-vars format real-slot imag-slot)
  (:generator 2
    (store-freg-slot (complex-reg-real-offset y) format
      (load-reg x)
      (emit-load-float format (- (* real-slot n-word-bytes) other-pointer-lowtag)))
    (store-freg-slot (complex-reg-imag-offset y) format
      (load-reg x)
      (emit-load-float format (- (* imag-slot n-word-bytes) other-pointer-lowtag)))))

(define-vop (move-to-complex-single move-to-complex-float)
  (:results (y :scs (complex-single-reg)))
  (:variant :single complex-single-float-real-slot complex-single-float-imag-slot))
(define-move-vop move-to-complex-single :move
  (descriptor-reg) (complex-single-reg))

(define-vop (move-to-complex-double move-to-complex-float)
  (:results (y :scs (complex-double-reg)))
  (:variant :double complex-double-float-real-slot complex-double-float-imag-slot))
(define-move-vop move-to-complex-double :move
  (descriptor-reg) (complex-double-reg))

;;; Complex float move-arg VOPs.
(macrolet ((frob (name format size sc stack-sc)
             `(progn
                (define-vop (,name)
                  (:args (x :scs (,sc) :target y)
                         (nfp :scs (any-reg) :load-if (not (sc-is y ,sc))))
                  (:results (y))
                  (:note "complex float arg move")
                  (:generator 2
                    (sc-case y
                      (,sc
                       (move-complex ,format y x))
                      (,stack-sc
                       (let ((offset (tn-byte-offset y)))
                         (load-reg nfp)
                         (emit-store-float ,format offset
                           (load-freg-slot (complex-reg-real-offset x) ,format))
                         (load-reg nfp)
                         (emit-store-float ,format (+ offset ,size)
                           (load-freg-slot (complex-reg-imag-offset x) ,format)))))))
                (define-move-vop ,name :move-arg
                  (,sc descriptor-reg) (,sc)))))
  (frob move-complex-single-float-arg :single 4 complex-single-reg complex-single-stack)
  (frob move-complex-double-float-arg :double 8 complex-double-reg complex-double-stack))

(define-move-vop move-arg :move-arg
  (single-reg double-reg complex-single-reg complex-double-reg)
  (descriptor-reg))

;;;; Arithmetic VOPs

(define-vop (float-op)
  (:args (x) (y))
  (:results (r))
  (:policy :fast-safe)
  (:note "inline float arithmetic")
  (:vop-var vop)
  (:save-p :compute-only))

(macrolet ((frob (name sc ptype)
             `(define-vop (,name float-op)
                (:args (x :scs (,sc))
                       (y :scs (,sc)))
                (:results (r :scs (,sc)))
                (:arg-types ,ptype ,ptype)
                (:result-types ,ptype))))
  (frob single-float-op single-reg single-float)
  (frob double-float-op double-reg double-float))

(macrolet ((frob (op sinst dinst sname scost dname dcost)
             `(progn
                (define-vop (,sname single-float-op)
                  (:translate ,op)
                  (:generator ,scost
                    (store-freg r :single
                      (load-freg x :single)
                      (load-freg y :single)
                      (inst ,sinst))))
                (define-vop (,dname double-float-op)
                  (:translate ,op)
                  (:generator ,dcost
                    (store-freg r :double
                      (load-freg x :double)
                      (load-freg y :double)
                      (inst ,dinst)))))))
  (frob + f32.add f64.add +/single-float 2 +/double-float 2)
  (frob - f32.sub f64.sub -/single-float 2 -/double-float 2)
  (frob * f32.mul f64.mul */single-float 4 */double-float 4)
  (frob / f32.div f64.div //single-float 12 //double-float 12))

(macrolet ((frob (name inst fmt translate sc type)
             `(define-vop (,name)
                (:args (x :scs (,sc)))
                (:results (y :scs (,sc)))
                (:translate ,translate)
                (:policy :fast-safe)
                (:arg-types ,type)
                (:result-types ,type)
                (:note "inline float arithmetic")
                (:vop-var vop)
                (:save-p :compute-only)
                (:generator 1
                  (note-this-location vop :internal-error)
                  (store-freg y ,fmt
                    (load-freg x ,fmt)
                    (inst ,inst))))))
  (frob abs/single-float f32.abs :single abs single-reg single-float)
  (frob abs/double-float f64.abs :double abs double-reg double-float)
  (frob %negate/single-float f32.neg :single %negate single-reg single-float)
  (frob %negate/double-float f64.neg :double %negate double-reg double-float))

;;;; Comparison

(define-vop (float-compare)
  (:args (x) (y))
  (:conditional)
  (:info target not-p)
  (:policy :fast-safe)
  (:note "inline float comparison")
  (:vop-var vop)
  (:save-p :compute-only))

(macrolet ((frob (name sc ptype)
             `(define-vop (,name float-compare)
                (:args (x :scs (,sc))
                       (y :scs (,sc)))
                (:arg-types ,ptype ,ptype))))
  (frob single-float-compare single-reg single-float)
  (frob double-float-compare double-reg double-float))

(macrolet ((frob (translate sinst dinst sname dname)
             `(progn
                (define-vop (,sname single-float-compare)
                  (:translate ,translate)
                  (:generator 3
                    (note-this-location vop :internal-error)
                    (load-freg x :single)
                    (load-freg y :single)
                    (inst ,sinst)
                    (emit-conditional-branch target not-p)))
                (define-vop (,dname double-float-compare)
                  (:translate ,translate)
                  (:generator 3
                    (note-this-location vop :internal-error)
                    (load-freg x :double)
                    (load-freg y :double)
                    (inst ,dinst)
                    (emit-conditional-branch target not-p))))))
  (frob < f32.lt f64.lt </single-float </double-float)
  (frob quiet< f32.lt f64.lt quiet</single-float quiet</double-float)
  (frob <= f32.le f64.le <=/single-float <=/double-float)
  (frob > f32.gt f64.gt >/single-float >/double-float)
  (frob >= f32.ge f64.ge >=/single-float >=/double-float)
  (frob = f32.eq f64.eq =/single-float =/double-float)
  (frob quiet= f32.eq f64.eq quiet=/single-float quiet=/double-float))

;;;; Conversion:

(macrolet ((frob (name translate inst from-sc from-type from-format
                       to-sc to-type to-format)
             `(define-vop (,name)
                (:args (x :scs (,from-sc)))
                (:results (y :scs (,to-sc)))
                (:arg-types ,from-type)
                (:result-types ,to-type)
                (:policy :fast-safe)
                (:note "inline float coercion")
                (:translate ,translate)
                (:vop-var vop)
                (:save-p :compute-only)
                (:generator 2
                  (note-this-location vop :internal-error)
                  (store-freg y ,to-format
                    ,(if from-format
                         `(load-freg x ,from-format)
                         `(load-reg x))
                    (inst ,inst))))))
  (frob %single-float/signed %single-float f32.convert_i32_s
    signed-reg signed-num nil
    single-reg single-float :single)
  (frob %single-float/unsigned %single-float f32.convert_i32_u
    unsigned-reg unsigned-num nil
    single-reg single-float :single)
  (frob %double-float/signed %double-float f64.convert_i32_s
    signed-reg signed-num nil
    double-reg double-float :double)
  (frob %double-float/unsigned %double-float f64.convert_i32_u
    unsigned-reg unsigned-num nil
    double-reg double-float :double)
  (frob %single-float/double-float %single-float f32.demote_f64
    double-reg double-float :double
    single-reg single-float :single)
  (frob %double-float/single-float %double-float f64.promote_f32
    single-reg single-float :single
    double-reg double-float :double))

;;; Truncation and rounding to a word. The saturating conversions do
;;; not trap; the result type guarantees the value fits.
(macrolet ((frob (name trans from-sc from-type from-format round)
             `(define-vop (,name)
                (:args (x :scs (,from-sc)))
                (:results (y :scs (signed-reg)))
                (:arg-types ,from-type)
                (:result-types signed-num)
                (:translate ,trans)
                (:policy :fast-safe)
                (:note "inline float round/truncate")
                (:vop-var vop)
                (:save-p :compute-only)
                (:generator 2
                  (note-this-location vop :internal-error)
                  (store-reg y
                    (load-freg x ,from-format)
                    ,@(when round
                        `((inst ,(ecase from-format (:single 'f32.nearest) (:double 'f64.nearest)))))
                    (inst ,(ecase from-format
                             (:single 'i32.trunc_sat_f32_s)
                             (:double 'i32.trunc_sat_f64_s))))))))
  (frob %unary-round/single-float %unary-round single-reg single-float :single t)
  (frob %unary-round/double-float %unary-round double-reg double-float :double t)
  (frob %unary-truncate/single-float %unary-truncate/single-float single-reg single-float :single nil)
  (frob %unary-truncate/double-float %unary-truncate/double-float double-reg double-float :double nil))

(define-vop (make-single-float)
   (:args (bits :scs (signed-reg)))
   (:results (res :scs (single-reg)))
   (:arg-types signed-num)
   (:result-types single-float)
   (:translate make-single-float)
   (:policy :fast-safe)
   (:generator 1
     (store-freg res :single
       (load-reg bits)
       (inst f32.reinterpret_i32))))

(define-vop (make-double-float)
  (:args (hi-bits :scs (signed-reg))
         (lo-bits :scs (unsigned-reg)))
  (:results (res :scs (double-reg)))
  (:arg-types signed-num unsigned-num)
  (:result-types double-float)
  (:translate make-double-float)
  (:policy :fast-safe)
  (:generator 2
    (store-freg res :double
      (load-reg hi-bits)
      (inst i64.extend_i32_u)
      (inst i64.const 32)
      (inst i64.shl)
      (load-reg lo-bits)
      (inst i64.extend_i32_u)
      (inst i64.or)
      (inst f64.reinterpret_i64))))

(define-vop (single-float-bits)
  (:args (float :scs (single-reg descriptor-reg)
                :load-if (not (sc-is float single-stack))))
  (:results (bits :scs (signed-reg)
                  :load-if (sc-is float descriptor-reg single-stack)))
  (:arg-types single-float)
  (:result-types signed-num)
  (:translate single-float-bits)
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 1
    (store-reg bits
      (sc-case float
        (single-reg
         (load-freg float :single)
         (inst i32.reinterpret_f32))
        (single-stack
         (load-reg (current-nfp-tn vop))
         (inst i32.load (tn-byte-offset float)))
        (descriptor-reg
         (load-reg float)
         (emit-load-word (- (* single-float-value-slot n-word-bytes) other-pointer-lowtag)))))))

(define-vop (double-float-high-bits)
  (:args (float :scs (double-reg descriptor-reg)
                :load-if (not (sc-is float double-stack))))
  (:results (hi-bits :scs (signed-reg)))
  (:arg-types double-float)
  (:result-types signed-num)
  (:translate double-float-high-bits)
  (:vop-var vop)
  (:policy :fast-safe)
  (:generator 2
    (store-reg hi-bits
      (sc-case float
        (double-reg
         (load-freg float :double)
         (inst i64.reinterpret_f64)
         (inst i64.const 32)
         (inst i64.shr_u)
         (inst i32.wrap_i64))
        (double-stack
         (load-reg (current-nfp-tn vop))
         (inst i32.load (+ (tn-byte-offset float) 4)))
        (descriptor-reg
         (load-reg float)
         (emit-load-word (- (+ (* double-float-value-slot n-word-bytes) 4)
                            other-pointer-lowtag)))))))

(define-vop (double-float-low-bits)
  (:args (float :scs (double-reg descriptor-reg)
                :load-if (not (sc-is float double-stack))))
  (:results (lo-bits :scs (unsigned-reg)))
  (:arg-types double-float)
  (:result-types unsigned-num)
  (:translate double-float-low-bits)
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 2
    (store-reg lo-bits
      (sc-case float
        (double-reg
         (load-freg float :double)
         (inst i64.reinterpret_f64)
         (inst i32.wrap_i64))
        (double-stack
         (load-reg (current-nfp-tn vop))
         (inst i32.load (tn-byte-offset float)))
        (descriptor-reg
         (load-reg float)
         (emit-load-word (- (* double-float-value-slot n-word-bytes)
                            other-pointer-lowtag)))))))

;;;; Float mode hackery:
;;;;
;;;; Wasm has no rounding-mode or trap-enable state: the modes word is a
;;;; software value kept in the thread area (doc/wasm-port/02-design.md,
;;;; 2.1), read and written here but not acted on by the engine.

(sb-xc:deftype float-modes () '(unsigned-byte 32))
(defknown floating-point-modes () float-modes (flushable))
(defknown ((setf floating-point-modes)) (float-modes)
  float-modes)

(define-vop (floating-point-modes)
  (:results (res :scs (unsigned-reg)))
  (:result-types unsigned-num)
  (:translate floating-point-modes)
  (:policy :fast-safe)
  (:generator 3
    (store-reg res
      (inst global.get +thread-global+)
      (inst i32.load +thread-float-modes-offset+))))

(define-vop (set-floating-point-modes)
  (:args (new :scs (unsigned-reg) :target res))
  (:results (res :scs (unsigned-reg)))
  (:arg-types unsigned-num)
  (:result-types unsigned-num)
  (:translate (setf floating-point-modes))
  (:policy :fast-safe)
  (:generator 3
    (inst global.get +thread-global+)
    (load-reg new)
    (inst i32.store +thread-float-modes-offset+)
    (move res new)))

;;;; Complex float VOPs

(define-vop (make-complex-single-float)
  (:translate complex)
  (:args (real :scs (single-reg) :target r
               :load-if (not (location= real r)))
         (imag :scs (single-reg) :to :save))
  (:arg-types single-float single-float)
  (:results (r :scs (complex-single-reg) :from (:argument 0)
               :load-if (not (sc-is r complex-single-stack))))
  (:result-types complex-single-float)
  (:note "inline complex single-float creation")
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 5
    (sc-case r
      (complex-single-reg
       (unless (= (tn-offset real) (complex-reg-real-offset r))
         (store-freg-slot (complex-reg-real-offset r) :single (load-freg real :single)))
       (unless (= (tn-offset imag) (complex-reg-imag-offset r))
         (store-freg-slot (complex-reg-imag-offset r) :single (load-freg imag :single))))
      (complex-single-stack
       (let ((nfp (current-nfp-tn vop))
             (offset (tn-byte-offset r)))
         (load-reg nfp)
         (emit-store-float :single offset (load-freg real :single))
         (load-reg nfp)
         (emit-store-float :single (+ offset 4) (load-freg imag :single)))))))

(define-vop (make-complex-double-float)
  (:translate complex)
  (:args (real :scs (double-reg) :target r
               :load-if (not (location= real r)))
         (imag :scs (double-reg) :to :save))
  (:arg-types double-float double-float)
  (:results (r :scs (complex-double-reg) :from (:argument 0)
               :load-if (not (sc-is r complex-double-stack))))
  (:result-types complex-double-float)
  (:note "inline complex double-float creation")
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 5
    (sc-case r
      (complex-double-reg
       (unless (= (tn-offset real) (complex-reg-real-offset r))
         (store-freg-slot (complex-reg-real-offset r) :double (load-freg real :double)))
       (unless (= (tn-offset imag) (complex-reg-imag-offset r))
         (store-freg-slot (complex-reg-imag-offset r) :double (load-freg imag :double))))
      (complex-double-stack
       (let ((nfp (current-nfp-tn vop))
             (offset (tn-byte-offset r)))
         (load-reg nfp)
         (emit-store-float :double offset (load-freg real :double))
         (load-reg nfp)
         (emit-store-float :double (+ offset 8) (load-freg imag :double)))))))

(define-vop (complex-single-float-value)
  (:args (x :scs (complex-single-reg) :target r
            :load-if (not (sc-is x complex-single-stack))))
  (:arg-types complex-single-float)
  (:results (r :scs (single-reg)))
  (:result-types single-float)
  (:variant-vars slot)
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 3
    (sc-case x
      (complex-single-reg
       (let ((source (ecase slot
                       (:real (complex-reg-real-offset x))
                       (:imag (complex-reg-imag-offset x)))))
         (unless (= source (tn-offset r))
           (store-freg r :single (load-freg-slot source :single)))))
      (complex-single-stack
       (store-freg r :single
         (load-reg (current-nfp-tn vop))
         (inst f32.load (+ (ecase slot (:real 0) (:imag 4))
                           (tn-byte-offset x))))))))

(define-vop (realpart/complex-single-float complex-single-float-value)
  (:translate realpart)
  (:note "complex single float realpart")
  (:variant :real))

(define-vop (imagpart/complex-single-float complex-single-float-value)
  (:translate imagpart)
  (:note "complex single float imagpart")
  (:variant :imag))

(define-vop (complex-double-float-value)
  (:args (x :scs (complex-double-reg) :target r
            :load-if (not (sc-is x complex-double-stack))))
  (:arg-types complex-double-float)
  (:results (r :scs (double-reg)))
  (:result-types double-float)
  (:variant-vars slot)
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 3
    (sc-case x
      (complex-double-reg
       (let ((source (ecase slot
                       (:real (complex-reg-real-offset x))
                       (:imag (complex-reg-imag-offset x)))))
         (unless (= source (tn-offset r))
           (store-freg r :double (load-freg-slot source :double)))))
      (complex-double-stack
       (store-freg r :double
         (load-reg (current-nfp-tn vop))
         (inst f64.load (+ (ecase slot (:real 0) (:imag 8))
                           (tn-byte-offset x))))))))

(define-vop (realpart/complex-double-float complex-double-float-value)
  (:translate realpart)
  (:note "complex double float realpart")
  (:variant :real))

(define-vop (imagpart/complex-double-float complex-double-float-value)
  (:translate imagpart)
  (:note "complex double float imagpart")
  (:variant :imag))
