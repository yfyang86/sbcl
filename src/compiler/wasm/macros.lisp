;;;; a bunch of handy macros for the WebAssembly backend

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Thread area layout and runtime imports
;;;;
;;;; The register file, float registers and the error-argument area live
;;;; at fixed byte offsets from the thread pointer, Wasm global 0. Runtime
;;;; entry points are imported functions at fixed indices; every module
;;;; the backend emits declares them in this order (see
;;;; MAKE-LISP-MODULE in func-asm.lisp), so VOPs can CALL them by number.

(defconstant +thread-registers-offset+ 0)          ; 32 words
(defconstant +thread-float-registers-offset+ 128)  ; 32 x 8 bytes
(defconstant +thread-error-args-offset+ 384)       ; 16 words
(defconstant +thread-area-bytes+ 512)

(defconstant +import-internal-error+ 0)   ; (kind code nargs) -> trap
(defconstant +import-alloc+ 1)            ; (nbytes) -> address
(defconstant +import-alloc-list+ 2)       ; (nbytes) -> address
(defconstant +import-pending-interrupt+ 3) ; () -> ()
(defconstant +n-runtime-imports+ 4)

;;;; Register access
;;;;
;;;; Registers are word slots in the register area of the thread
;;;; structure (see vm.lisp). $thread is Wasm global 0 in every module the
;;;; backend emits. LOAD-REG pushes a register's value on the Wasm
;;;; operand stack; STORE-REG pops the operand stack into a register.
;;;; These two macros are the only place that knows where registers
;;;; live, so that caching registers in Wasm locals later is a local
;;;; change (doc/wasm-port/02-design.md, 2.4).

(defconstant +thread-global+ 0)

;;; Byte offset of register slot N within the thread structure. The
;;; register area starts at the slot named REGISTER-AREA in the thread
;;; primitive object once that is defined (Sprint 3); until then the
;;; offset is symbolic.
(defmacro register-byte-offset (n)
  `(+ +thread-registers-offset+ (* ,n n-word-bytes)))

(defmacro float-register-byte-offset (n)
  `(+ +thread-float-registers-offset+ (* ,n 8)))

(defmacro load-reg (tn)
  "Push the word in register TN."
  `(progn
     (inst global.get +thread-global+)
     (inst i32.load (register-byte-offset (tn-offset ,tn)))))

(defmacro store-reg (tn &body value-forms)
  "Evaluate VALUE-FORMS, which push one i32, and store it into register TN."
  `(progn
     (inst global.get +thread-global+)
     ,@value-forms
     (inst i32.store (register-byte-offset (tn-offset ,tn)))))

;;; Instruction-like macros.
(defmacro move (dst src)
  "Move SRC to DST unless they are location=."
  `(unless (location= ,dst ,src)
     (store-reg ,dst (load-reg ,src))))

;;;; Float register access. Float registers are 8-byte slots; a single
;;;; float occupies the low four bytes of its slot.

(defmacro load-freg (tn format)
  "Push the float in float register TN as FORMAT (:single or :double)."
  `(progn
     (inst global.get +thread-global+)
     ,(ecase format
        (:single `(inst f32.load (float-register-byte-offset (tn-offset ,tn))))
        (:double `(inst f64.load (float-register-byte-offset (tn-offset ,tn)))))))

(defmacro store-freg (tn format &body value-forms)
  "Evaluate VALUE-FORMS, which push one FORMAT value, into float register TN."
  `(progn
     (inst global.get +thread-global+)
     ,@value-forms
     ,(ecase format
        (:single `(inst f32.store (float-register-byte-offset (tn-offset ,tn))))
        (:double `(inst f64.store (float-register-byte-offset (tn-offset ,tn)))))))

;;; The imaginary part of a complex float register is the next slot.
(defun complex-reg-real-offset (tn) (tn-offset tn))
(defun complex-reg-imag-offset (tn) (1+ (tn-offset tn)))

;;;; Memory access
;;;;
;;;; A memarg offset is unsigned, so a negative displacement (a header
;;;; word reached through a lowtag) is folded into the address instead.

(defun emit-load-word (displacement)
  "With an address on the operand stack, push the word at address+DISPLACEMENT."
  (cond ((>= displacement 0)
         (inst i32.load displacement))
        (t
         (inst i32.const displacement)
         (inst i32.add)
         (inst i32.load 0))))

(defmacro emit-store-word (displacement &body value-forms)
  "With an address on the operand stack, store the word pushed by
VALUE-FORMS at address+DISPLACEMENT."
  (let ((d (gensym "DISPLACEMENT")))
    `(let ((,d ,displacement))
       (cond ((>= ,d 0)
              ,@value-forms
              (inst i32.store ,d))
             (t
              (inst i32.const ,d)
              (inst i32.add)
              ,@value-forms
              (inst i32.store 0))))))

(defmacro loadw (result base &optional (offset 0) (lowtag 0))
  "Load word OFFSET of the object in register BASE (with LOWTAG) into RESULT."
  `(store-reg ,result
     (load-reg ,base)
     (emit-load-word (- (ash ,offset word-shift) ,lowtag))))

(defmacro storew (value base &optional (offset 0) (lowtag 0))
  "Store register VALUE into word OFFSET of the object in register BASE."
  `(progn
     (load-reg ,base)
     (emit-store-word (- (ash ,offset word-shift) ,lowtag)
       (load-reg ,value))))

;;;; Immediates and symbols

(defmacro load-immediate-word (result value)
  `(store-reg ,result (inst i32.const ,value)))

(defun static-symbol-address (symbol)
  (+ nil-value (static-symbol-offset symbol)))

(defmacro load-symbol (result symbol)
  `(load-immediate-word ,result (static-symbol-address ,symbol)))

(defmacro load-symbol-value (result symbol)
  `(store-reg ,result
     (inst i32.const (+ (static-symbol-address ',symbol)
                        (ash symbol-value-slot word-shift)
                        (- other-pointer-lowtag)))
     (inst i32.load 0)))

(defmacro store-symbol-value (value symbol)
  `(progn
     (inst i32.const (+ (static-symbol-address ',symbol)
                        (ash symbol-value-slot word-shift)
                        (- other-pointer-lowtag)))
     (load-reg ,value)
     (inst i32.store 0)))

;;;; Stack slots
;;;;
;;;; The control stack grows upward; frame slot N of the current frame is
;;;; at CFP + N words. Number-stack slots are addressed from the current
;;;; frame's NFP the same way.

(defun load-frame-word (result base wordindex)
  (store-reg result
    (load-reg base)
    (inst i32.load (ash wordindex word-shift))))

(defun store-frame-word (value base wordindex)
  (load-reg base)
  (load-reg value)
  (inst i32.store (ash wordindex word-shift)))

(defmacro load-stack-tn (reg stack)
  `(let ((reg ,reg) (stack ,stack))
     (sc-case stack
       ((control-stack)
        (load-frame-word reg cfp-tn (tn-offset stack))))))

(defmacro store-stack-tn (stack reg)
  `(let ((stack ,stack) (reg ,reg))
     (sc-case stack
       ((control-stack)
        (store-frame-word reg cfp-tn (tn-offset stack))))))

(defmacro maybe-load-stack-tn (reg reg-or-stack)
  "Move a stacked TN or another register to REG."
  (once-only ((n-reg reg) (n-stack reg-or-stack))
    `(sc-case ,n-reg
       ((any-reg descriptor-reg)
        (sc-case ,n-stack
          ((any-reg descriptor-reg)
           (move ,n-reg ,n-stack))
          ((control-stack)
           (load-stack-tn ,n-reg ,n-stack)))))))

;;;; Dynamic-state cells. Without threads these are static symbols.

(defmacro load-binding-stack-pointer (reg)
  `(load-symbol-value ,reg *binding-stack-pointer*))
(defmacro store-binding-stack-pointer (reg)
  `(store-symbol-value ,reg *binding-stack-pointer*))
(defmacro load-current-catch-block (reg)
  `(load-symbol-value ,reg *current-catch-block*))
(defmacro store-current-catch-block (reg)
  `(store-symbol-value ,reg *current-catch-block*))
(defmacro load-current-unwind-protect-block (reg)
  `(load-symbol-value ,reg *current-unwind-protect-block*))
(defmacro store-current-unwind-protect-block (reg)
  `(store-symbol-value ,reg *current-unwind-protect-block*))

;;;; Constant-index addressing
;;;;
;;;; A memarg offset is an unsigned 32-bit displacement, so any constant
;;;; index whose byte displacement (after the lowtag adjustment) is
;;;; non-negative and below 2^31 can be folded into the instruction.

(sb-xc:deftype load/store-index (scale lowtag offset)
  (let* ((min-byte (- lowtag (* offset n-word-bytes)))
         (max-byte (- (1- (ash 1 31)) (* offset n-word-bytes) (- lowtag))))
    `(integer ,(ceiling min-byte scale) ,(floor max-byte scale))))

;;;; Placeholders
;;;;
;;;; A VOP whose generator is not written yet has a placeholder generator
;;;; so that the compiler front end, which refers to VOPs by name, can be
;;;; built. Generating code through one is a bug, not silent misbehaviour.

;;; While the backend is incomplete, a missing generator emits UNREACHABLE
;;; and is recorded, so that the whole source tree can be cross-compiled
;;; for its compile-time effects and the differential test rig can report
;;; which VOPs a test needs. *WASM-UNIMPLEMENTED* counts every use;
;;; *WASM-COMPONENT-UNIMPLEMENTED* collects the names for the component
;;; being generated (see WASM-NOTE-COMPONENT).
;;; The three variables are defined in func-asm.lisp, which is compiled
;;; before this file and consumes *WASM-COMPONENT-UNIMPLEMENTED*.

(defun vop-not-yet-implemented (name &rest operands)
  (declare (ignore operands))
  (when *wasm-strict-vops*
    (bug "VOP ~S is not implemented on this target yet" name))
  (incf (gethash name *wasm-unimplemented* 0))
  (pushnew name *wasm-component-unimplemented*)
  ;; only inside a generator; a placeholder called at IR2 time just counts
  (when (boundp 'sb-assem::*current-destination*)
    (inst unreachable)))

(defun report-unimplemented-vops (&optional (stream *standard-output*))
  (let ((entries '()))
    (maphash (lambda (name count) (push (cons name count) entries)) *wasm-unimplemented*)
    (setf entries (sort entries #'> :key #'cdr))
    (format stream "~&~D unimplemented VOPs used ~D times~%"
            (length entries) (reduce #'+ entries :key #'cdr))
    (loop for (name . count) in entries
          do (format stream "~8D ~S~%" count name))
    entries))

;;;; Error traps
;;;;
;;;; An internal error stores the SC+OFFSET descriptor of each value into
;;;; the thread's error-argument area and calls the runtime's
;;;; internal_error import with the trap kind, the error code and the
;;;; number of values; it does not return.

;;; The SC+OFFSET word describing one error argument, as
;;; ENCODE-INTERNAL-ERROR-ARGS (generic/type-error.lisp) computes it for
;;; the byte-encoded targets: WHERE is a TN or an already packed word;
;;; an immediate fixnum is encoded as its value, an immediate symbol or
;;; layout as a constant, and an unallocated constant TN has offset 0.
(defun encode-error-arg (where)
  (cond ((not (tn-p where))
         where)
        ((and (sc-is where immediate)
              (fixnump (tn-value where)))
         (encode-immediate-error-arg (tn-value where)))
        (t
         (make-sc+offset (if (and (sc-is where immediate)
                                  (typep (tn-value where) '(or symbol layout)))
                             constant-sc-number
                             (sc-number (tn-sc where)))
                         (or (tn-offset where) 0)))))

(defun emit-error-break (vop kind code values)
  (assemble ()
    (when vop
      (note-this-location vop :internal-error))
    (loop for where in values
          for i from 0
          do (inst global.get +thread-global+)
             (inst i32.const (encode-error-arg where))
             (inst i32.store (+ +thread-error-args-offset+ (* i n-word-bytes))))
    (inst i32.const kind)
    (inst i32.const code)
    (inst i32.const (length values))
    (inst call +import-internal-error+)
    (inst unreachable)))

(defun generate-error-code (vop error-code &rest values)
  "Generate-Error-Code Error-code Value*
  Emit code for an error with the specified Error-Code and context Values."
  (assemble (:elsewhere)
    (let ((start-lab (gen-label)))
      (emit-label start-lab)
      (emit-error-break vop
                        (if (eq error-code 'invalid-arg-count-error)
                            invalid-arg-count-trap
                            error-trap)
                        (error-number-or-lose error-code) values)
      start-lab)))

;;;; Stack frames

(defconstant +number-stack-alignment-mask+ 15)

(defun bytes-needed-for-non-descriptor-stack-frame ()
  (logandc2 (+ (* (sb-allocated-size 'non-descriptor-stack) n-word-bytes)
               +number-stack-alignment-mask+)
            +number-stack-alignment-mask+))

;;; Push REG + CONSTANT.
(defmacro emit-reg-plus (reg constant)
  `(progn
     (load-reg ,reg)
     (inst i32.const ,constant)
     (inst i32.add)))

;;; Set the number stack pointer back to the frame's base.
(defun clear-number-stack (vop)
  (let ((nfp (current-nfp-tn vop)))
    (when nfp
      (store-reg nsp-tn
        (emit-reg-plus nfp (bytes-needed-for-non-descriptor-stack-frame))))))

;;;; Conditional VOP support
;;;;
;;;; A conditional VOP computes an i32 (nonzero = true) and branches to
;;;; TARGET; NOT-P inverts the sense.

(defmacro emit-conditional-branch (target not-p)
  `(progn
     (when ,not-p (inst i32.eqz))
     (inst jump-if ,target)))

;;; Emit the comparison instruction for CONDITION, one of :eq :ne :lt :le
;;; :gt :ge (signed) or :ltu :leu :gtu :geu (unsigned), with the two
;;; operands already on the stack.
(defun emit-compare (condition)
  (ecase condition
    (:eq (inst i32.eq)) (:ne (inst i32.ne))
    (:lt (inst i32.lt_s)) (:le (inst i32.le_s)) (:gt (inst i32.gt_s)) (:ge (inst i32.ge_s))
    (:ltu (inst i32.lt_u)) (:leu (inst i32.le_u)) (:gtu (inst i32.gt_u)) (:geu (inst i32.ge_u))))

;;;; Allocation through the runtime
;;;;
;;;; ALLOC returns the untagged address of NBYTES fresh zeroed bytes; the
;;;; result register gets the address with LOWTAG. GC may run inside the
;;;; slow path; all live Lisp values are in the register file or on the
;;;; control stack, so nothing needs saving (doc/wasm-port/02-design.md, 2.8).
(defmacro emit-allocate (result nbytes lowtag &key list)
  "Allocate NBYTES into RESULT with LOWTAG. NBYTES is a form that either
returns the byte count as an integer, or pushes it on the operand stack
and returns :PUSHED."
  (let ((n (gensym "NBYTES")))
    `(store-reg ,result
       (let ((,n ,nbytes))
         (if (integerp ,n)
             (inst i32.const ,n)
             (aver (eq ,n :pushed))))
       (inst call ,(if list '+import-alloc-list+ '+import-alloc+))
       (inst i32.const ,lowtag)
       (inst i32.or))))

;;; Allocate a boxed object of WORDS words (including the header) with
;;; TYPE-CODE, storing the header word.
(defmacro with-fixed-allocation ((result-tn type-code size &key (lowtag other-pointer-lowtag))
                                 &body body)
  `(progn
     (emit-allocate ,result-tn (pad-data-block ,size) ,lowtag)
     (load-reg ,result-tn)
     (emit-store-word (- ,lowtag)
       (inst i32.const (compute-object-header ,size ,type-code)))
     ,@body))

;;;; Indexed memory access
;;;;
;;;; A fixnum index equals its byte offset for word-sized elements since
;;;; the fixnum tag width is the word shift; smaller elements shift the
;;;; index right. The displacement that combines the element offset and
;;;; the lowtag is folded into the address by EMIT-LOAD-WORD and friends
;;;; when it is negative, and into the memarg otherwise.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (assert (= word-shift n-fixnum-tag-bits)))

(defun emit-indexed-address (object index size)
  "Push the address of element INDEX (a fixnum in a register) of SIZE
bytes in OBJECT, without the displacement."
  (load-reg object)
  (load-reg index)
  (let ((shift (- (1- (integer-length size)) word-shift)))
    (cond ((plusp shift)
           (inst i32.const shift)
           (inst i32.shl))
          ((minusp shift)
           (inst i32.const (- shift))
           (inst i32.shr_u))))
  (inst i32.add))

(defun emit-load-sized (size signed displacement)
  "With an address on the stack, push the SIZE-byte element at
address+DISPLACEMENT, sign- or zero-extended."
  (when (minusp displacement)
    (inst i32.const displacement)
    (inst i32.add)
    (setf displacement 0))
  (ecase size
    (1 (if signed (inst i32.load8_s displacement) (inst i32.load8_u displacement)))
    (2 (if signed (inst i32.load16_s displacement) (inst i32.load16_u displacement)))
    (4 (inst i32.load displacement))))

(defmacro emit-store-sized (size displacement &body value-forms)
  "With an address on the stack, store the low SIZE bytes of the i32
pushed by VALUE-FORMS at address+DISPLACEMENT."
  (let ((d (gensym "DISPLACEMENT")))
    `(let ((,d ,displacement))
       (when (minusp ,d)
         (inst i32.const ,d)
         (inst i32.add)
         (setf ,d 0))
       ,@value-forms
       (ecase ,size
         (1 (inst i32.store8 ,d))
         (2 (inst i32.store16 ,d))
         (4 (inst i32.store ,d))))))

(defmacro define-full-reffer (name type offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg)))
       (:arg-types ,type tagged-num)
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 5
         (store-reg value
           (emit-indexed-address object index n-word-bytes)
           (emit-load-word (- (ash ,offset word-shift) ,lowtag)))))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset))))
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 4
         (loadw value object (+ ,offset index) ,lowtag)))))

(defmacro define-full-setter (name type offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg))
              (value :scs ,scs))
       (:arg-types ,type tagged-num ,eltype)
       (:generator 3
         (emit-indexed-address object index n-word-bytes)
         (emit-store-word (- (ash ,offset word-shift) ,lowtag)
           (load-reg value))))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (value :scs ,scs))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index #.n-word-bytes ,(eval lowtag) ,(eval offset)))
         ,eltype)
       (:generator 1
         (storew value object (+ ,offset index) ,lowtag)))))

(defmacro define-partial-reffer (name type size signed offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg)))
       (:arg-types ,type positive-fixnum)
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 5
         (store-reg value
           (emit-indexed-address object index ,size)
           (emit-load-sized ,size ,signed (- (ash ,offset word-shift) ,lowtag)))))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg)))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index ,size ,(eval lowtag) ,(eval offset))))
       (:results (value :scs ,scs))
       (:result-types ,eltype)
       (:generator 4
         (store-reg value
           (load-reg object)
           (emit-load-sized ,size ,signed
                            (- (+ (ash ,offset word-shift) (* index ,size)) ,lowtag)))))))

(defmacro define-partial-setter (name type size offset lowtag scs eltype &optional translate)
  `(progn
     (define-vop (,name)
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (index :scs (any-reg))
              (value :scs ,scs))
       (:arg-types ,type positive-fixnum ,eltype)
       (:generator 5
         (emit-indexed-address object index ,size)
         (emit-store-sized ,size (- (ash ,offset word-shift) ,lowtag)
           (load-reg value))))
     (define-vop (,(symbolicate name "-C"))
       ,@(when translate `((:translate ,translate)))
       (:policy :fast-safe)
       (:args (object :scs (descriptor-reg))
              (value :scs ,scs))
       (:info index)
       (:arg-types ,type
         (:constant (load/store-index ,size ,(eval lowtag) ,(eval offset)))
         ,eltype)
       (:generator 4
         (load-reg object)
         (emit-store-sized ,size (- (+ (ash ,offset word-shift) (* index ,size)) ,lowtag)
           (load-reg value))))))

;;;; Float memory access

(defmacro load-freg-slot (slot format)
  "Push the float in float register slot SLOT as FORMAT."
  `(progn
     (inst global.get +thread-global+)
     ,(ecase format
        (:single `(inst f32.load (float-register-byte-offset ,slot)))
        (:double `(inst f64.load (float-register-byte-offset ,slot))))))

(defmacro store-freg-slot (slot format &body value-forms)
  "Evaluate VALUE-FORMS, which push one FORMAT value, into float register slot SLOT."
  `(progn
     (inst global.get +thread-global+)
     ,@value-forms
     ,(ecase format
        (:single `(inst f32.store (float-register-byte-offset ,slot)))
        (:double `(inst f64.store (float-register-byte-offset ,slot))))))

(defun emit-load-float (format displacement)
  "With an address on the stack, push the FORMAT float at address+DISPLACEMENT."
  (when (minusp displacement)
    (inst i32.const displacement)
    (inst i32.add)
    (setf displacement 0))
  (ecase format
    (:single (inst f32.load displacement))
    (:double (inst f64.load displacement))))

(defmacro emit-store-float (format displacement &body value-forms)
  "With an address on the stack, store the FORMAT float pushed by
VALUE-FORMS at address+DISPLACEMENT."
  (let ((d (gensym "DISPLACEMENT")))
    `(let ((,d ,displacement))
       (when (minusp ,d)
         (inst i32.const ,d)
         (inst i32.add)
         (setf ,d 0))
       ,@value-forms
       ,(ecase format
          (:single `(inst f32.store ,d))
          (:double `(inst f64.store ,d))))))

;;; ARRAYP says whether INDEX counts elements of SIZE bytes (arrays) or
;;; words (raw instance slots).
(defmacro define-float-reffer (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((scale (if arrayp size n-word-bytes)))
    `(progn
       (define-vop (,name)
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (index :scs (any-reg)))
         (:arg-types ,type tagged-num)
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 5
           (store-freg value ,format
             (emit-indexed-address object index ,scale)
             (emit-load-float ,format (- (ash ,offset word-shift) ,lowtag)))))
       (define-vop (,(symbolicate name "-C"))
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg)))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,scale ,(eval lowtag) ,(eval offset))))
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 4
           (store-freg value ,format
             (load-reg object)
             (emit-load-float ,format (- (+ (ash ,offset word-shift) (* index ,scale)) ,lowtag))))))))

(defmacro define-float-setter (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((scale (if arrayp size n-word-bytes)))
    `(progn
       (define-vop (,name)
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (index :scs (any-reg))
                (value :scs ,scs))
         (:arg-types ,type tagged-num ,eltype)
         (:generator 5
           (emit-indexed-address object index ,scale)
           (emit-store-float ,format (- (ash ,offset word-shift) ,lowtag)
             (load-freg value ,format))))
       (define-vop (,(symbolicate name "-C"))
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (value :scs ,scs))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,scale ,(eval lowtag) ,(eval offset)))
           ,eltype)
         (:generator 4
           (load-reg object)
           (emit-store-float ,format (- (+ (ash ,offset word-shift) (* index ,scale)) ,lowtag)
             (load-freg value ,format)))))))

;;; A complex float occupies two consecutive float register slots and
;;; two consecutive SIZE-byte cells in memory.
(defmacro define-complex-float-reffer (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((scale (if arrayp (* 2 size) n-word-bytes)))
    `(progn
       (define-vop (,name)
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (index :scs (any-reg)))
         (:arg-types ,type tagged-num)
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 5
           (let ((displacement (- (ash ,offset word-shift) ,lowtag)))
             (store-freg-slot (complex-reg-real-offset value) ,format
               (emit-indexed-address object index ,scale)
               (emit-load-float ,format displacement))
             (store-freg-slot (complex-reg-imag-offset value) ,format
               (emit-indexed-address object index ,scale)
               (emit-load-float ,format (+ displacement ,size))))))
       (define-vop (,(symbolicate name "-C"))
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg)))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,scale ,(eval lowtag) ,(eval offset))))
         (:results (value :scs ,scs))
         (:result-types ,eltype)
         (:generator 4
           (let ((displacement (- (+ (ash ,offset word-shift) (* index ,scale)) ,lowtag)))
             (store-freg-slot (complex-reg-real-offset value) ,format
               (load-reg object)
               (emit-load-float ,format displacement))
             (store-freg-slot (complex-reg-imag-offset value) ,format
               (load-reg object)
               (emit-load-float ,format (+ displacement ,size)))))))))

(defmacro define-complex-float-setter (name type size format offset lowtag scs eltype &optional arrayp note translate)
  (let ((scale (if arrayp (* 2 size) n-word-bytes)))
    `(progn
       (define-vop (,name)
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (index :scs (any-reg))
                (value :scs ,scs))
         (:arg-types ,type tagged-num ,eltype)
         (:generator 5
           (let ((displacement (- (ash ,offset word-shift) ,lowtag)))
             (emit-indexed-address object index ,scale)
             (emit-store-float ,format displacement
               (load-freg-slot (complex-reg-real-offset value) ,format))
             (emit-indexed-address object index ,scale)
             (emit-store-float ,format (+ displacement ,size)
               (load-freg-slot (complex-reg-imag-offset value) ,format)))))
       (define-vop (,(symbolicate name "-C"))
         ,@(when note `((:note ,note)))
         ,@(when translate `((:translate ,translate)))
         (:policy :fast-safe)
         (:args (object :scs (descriptor-reg))
                (value :scs ,scs))
         (:info index)
         (:arg-types ,type
           (:constant (load/store-index ,scale ,(eval lowtag) ,(eval offset)))
           ,eltype)
         (:generator 4
           (let ((displacement (- (+ (ash ,offset word-shift) (* index ,scale)) ,lowtag)))
             (load-reg object)
             (emit-store-float ,format displacement
               (load-freg-slot (complex-reg-real-offset value) ,format))
             (load-reg object)
             (emit-store-float ,format (+ displacement ,size)
               (load-freg-slot (complex-reg-imag-offset value) ,format))))))))
