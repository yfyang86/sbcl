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
  `(* ,n n-word-bytes))

(defmacro float-register-byte-offset (n)
  `(+ (* 32 n-word-bytes) (* ,n 8)))

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

(defun vop-not-yet-implemented (name &rest operands)
  (declare (ignore operands))
  (bug "VOP ~S is not implemented on this target yet" name))

;;;; Error traps
;;;;
;;;; An internal error is a call into the runtime carrying the trap kind,
;;;; the error code and the SC+OFFSET descriptors of the values (Sprint 3).

(defun emit-error-break (vop kind code values)
  (declare (ignore vop kind code values))
  (vop-not-yet-implemented 'emit-error-break))
