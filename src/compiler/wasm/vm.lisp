;;;; miscellaneous VM definition noise for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;; :ABSOLUTE patches a raw little-endian word (in constant vectors and
;;; data); :LEB128 patches a fixed-width five-byte LEB128 immediate inside
;;; an instruction (i32.const of an address that is only known at load
;;; time).
(defconstant-eqx +fixup-kinds+ #(:absolute :leb128) #'equalp)

;;;; The register file
;;;;
;;;; Wasm has no registers that the garbage collector could see. The
;;;; "registers" of this backend are word slots in a fixed area of the
;;;; thread structure, addressed from the Wasm global $thread; a register
;;;; number is an index into that area. Every VOP reads and writes them
;;;; through LOAD-REG and STORE-REG (see macros.lisp). Descriptor
;;;; registers are conservative GC roots exactly like the boxed registers
;;;; of an interrupt context on other targets. See
;;;; doc/wasm-port/02-design.md, 2.4.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *register-names* (make-array 32 :initial-element nil)))

(macrolet ((defreg (name offset)
             (let ((offset-sym (symbolicate name "-OFFSET")))
               `(eval-when (:compile-toplevel :load-toplevel :execute)
                  (defconstant ,offset-sym ,offset)
                  (setf (svref *register-names* ,offset-sym) ,(symbol-name name)))))
           (define-argument-register-set (&rest args)
             `(progn
                (defregset *register-arg-offsets* ,@args)
                (defconstant register-arg-count ,(length args)))))
  ;; control registers
  (defreg nargs 0)      ; argument count (fixnum)
  (defreg csp 1)        ; control stack pointer
  (defreg cfp 2)        ; control frame pointer
  (defreg ocfp 3)       ; old control frame pointer
  (defreg nfp 4)        ; number stack frame pointer
  (defreg nsp 5)        ; number (non-descriptor) stack pointer
  (defreg lexenv 6)     ; the function object being called
  (defreg code 7)       ; the code component of the running function
  (defreg lip 8)        ; interior pointer scratch
  (defreg cfunc 9)      ; C function (table index) for call-out
  ;; argument-passing descriptor registers
  (defreg a0 10)
  (defreg a1 11)
  (defreg a2 12)
  (defreg a3 13)
  ;; descriptor temporaries
  (defreg l0 14)
  (defreg l1 15)
  (defreg l2 16)
  (defreg l3 17)
  (defreg l4 18)
  (defreg l5 19)
  ;; non-descriptor temporaries
  (defreg nl0 20)
  (defreg nl1 21)
  (defreg nl2 22)
  (defreg nl3 23)
  (defreg nl4 24)
  (defreg nl5 25)
  (defreg nl6 26)
  (defreg nl7 27)
  (defreg tmp 28)       ; scratch for macros; never allocated
  (defreg ra 29)        ; return-point descriptor of the current call
  (defreg thread 30)    ; reserved for #+sb-thread
  (defreg reserved 31)

  (defregset non-descriptor-regs nl0 nl1 nl2 nl3 nl4 nl5 nl6 nl7 nargs nfp cfunc)
  (defregset descriptor-regs a0 a1 a2 a3 l0 l1 l2 l3 l4 l5 ocfp lexenv)
  (defregset reserve-descriptor-regs lexenv)
  (defregset reserve-non-descriptor-regs cfunc)
  ;; scanned by the GC as conservative roots
  (defregset boxed-regs a0 a1 a2 a3 l0 l1 l2 l3 l4 l5 ocfp lexenv code)

  (define-argument-register-set a0 a1 a2 a3))

;;; Float "registers" are 32 double-width slots following the word
;;; registers in the same area of the thread structure.
(defconstant n-float-registers 32)

(!define-storage-bases
 (define-storage-base registers :finite :size 32)
 (define-storage-base control-stack :unbounded :size 0)
 (define-storage-base non-descriptor-stack :unbounded :size 0)

 (define-storage-base float-registers :finite :size #.n-float-registers)

 (define-storage-base constant :non-packed)
 (define-storage-base immediate-constant :non-packed)
 )

(!define-storage-classes

 ;; Non-immediate constants in the constant pool
 (constant constant)

 ;; Immediate constant.
 (immediate immediate-constant)

 (control-stack control-stack)
 (any-reg registers
          :locations #.(append non-descriptor-regs descriptor-regs)
          :reserve-locations #.(append reserve-non-descriptor-regs
                                       reserve-descriptor-regs)
          :alternate-scs (control-stack)
          :constant-scs (immediate constant)
          :save-p t)

 ;; Pointer descriptor objects.  Must be seen by GC.
 (descriptor-reg registers
                 :locations #.descriptor-regs
                 :reserve-locations #.reserve-descriptor-regs
                 :alternate-scs (control-stack)
                 :constant-scs (immediate constant)
                 :save-p t)

 ;; Random objects that must not be seen by GC.  Used only as temporaries.
 (non-descriptor-reg registers :locations #.non-descriptor-regs)

 (character-stack non-descriptor-stack)

 ;; Non-Descriptor characters
 (character-reg registers
                :locations #.non-descriptor-regs
                :reserve-locations #.reserve-non-descriptor-regs
                :alternate-scs (character-stack)
                :constant-scs (immediate)
                :save-p t)

 (sap-stack non-descriptor-stack)
 (sap-reg registers
          :locations #.non-descriptor-regs
          :reserve-locations #.reserve-non-descriptor-regs
          :constant-scs (immediate)
          :alternate-scs (sap-stack)
          :save-p t)
 (signed-stack non-descriptor-stack)
 (signed-reg registers
             :locations #.non-descriptor-regs
             :reserve-locations #.reserve-non-descriptor-regs
             :alternate-scs (signed-stack)
             :constant-scs (immediate)
             :save-p t)
 (unsigned-stack non-descriptor-stack)
 (unsigned-reg registers
               :locations #.non-descriptor-regs
               :reserve-locations #.reserve-non-descriptor-regs
               :alternate-scs (unsigned-stack)
               :constant-scs (immediate)
               :save-p t)

 ;; Non-descriptor floating point.
 (single-stack non-descriptor-stack)
 (single-reg float-registers
             :locations #.(loop for i below n-float-registers collect i)
             :alternate-scs (single-stack)
             :save-p t)
 (double-stack non-descriptor-stack :element-size (/ 64 n-word-bits))
 (double-reg float-registers
             :locations #.(loop for i below n-float-registers collect i)
             :alternate-scs (double-stack)
             :save-p t)

 (complex-single-stack non-descriptor-stack :element-size (/ (* 2 32) n-word-bits))
 (complex-single-reg float-registers
                     :locations #.(loop for i below n-float-registers by 2 collect i)
                     :element-size 2
                     :alternate-scs (complex-single-stack)
                     :save-p t)
 (complex-double-stack non-descriptor-stack :element-size (/ (* 2 64) n-word-bits))
 (complex-double-reg float-registers
                     :locations #.(loop for i below n-float-registers by 2 collect i)
                     :element-size 2
                     :save-p t
                     :alternate-scs (complex-double-stack))

 (catch-block control-stack :element-size catch-block-size)
 (unwind-block control-stack :element-size unwind-block-size)
 )


(macrolet ((defregtn (name sc)
               (let ((offset-sym (symbolicate name "-OFFSET"))
                     (tn-sym (symbolicate name "-TN")))
                 `(defglobal ,tn-sym
                   (make-random-tn (sc-or-lose ',sc) ,offset-sym)))))
  (defregtn lip any-reg)
  (defregtn code descriptor-reg)

  (defregtn nargs any-reg)
  (defregtn lexenv descriptor-reg)

  (defregtn csp any-reg)
  (defregtn cfp any-reg)

  (defregtn nsp any-reg)
  (defregtn ocfp any-reg)
  (defregtn nfp any-reg)

  (defregtn ra any-reg)
  (defregtn cfunc unsigned-reg)

  (defregtn tmp unsigned-reg))

;;; If VALUE can be represented as an immediate constant, then return the
;;; appropriate SC number, otherwise return NIL. Every fixnum, character
;;; and static symbol is an immediate: i32.const takes any 32-bit value.
(defun immediate-constant-sc (value)
  (typecase value
    (null
     immediate-sc-number)
    (symbol
     (if (static-symbol-p value)
         immediate-sc-number
         nil))
    ((integer #.most-negative-fixnum #.most-positive-fixnum)
     immediate-sc-number)
    (character
     immediate-sc-number)
    (structure-object
     (when (eq value sb-lockless:+tail+)
       immediate-sc-number))))

(defun boxed-immediate-sc-p (sc)
  (eql sc immediate-sc-number))


;;; Offsets of special stack frame locations. There is no return address
;;; on this target; RA-SAVE-OFFSET holds the caller's return-point
;;; descriptor and CODE-SAVE-OFFSET the caller's code object, which
;;; together replace the LRA of other targets for the debugger.
(defconstant ocfp-save-offset 0)
(defconstant ra-save-offset 1)
(defconstant code-save-offset 2)
(defconstant nfp-save-offset 3)

(define-load-time-global *register-arg-tns*
  (let ((drsc (sc-or-lose 'descriptor-reg)))
    (flet ((make (n) (make-random-tn drsc n)))
      (mapcar #'make *register-arg-offsets*))))

;;; This is used by the debugger. Our calling convention for
;;; unknown-values return does not involve manipulating return
;;; addresses.
(defconstant single-value-return-byte-offset 0)

;;; This function is called by debug output routines that want a pretty name
;;; for a TN's location.  It returns a thing that can be printed with PRINC.
(defun location-print-name (tn)
  (declare (type tn tn))
  (let ((sb (sb-name (sc-sb (tn-sc tn))))
        (offset (tn-offset tn)))
    (ecase sb
      (registers (or (svref *register-names* offset)
                     (format nil "R~D" offset)))
      (float-registers (format nil "F~D" offset))
      (control-stack (format nil "CS~D" offset))
      (non-descriptor-stack (format nil "NS~D" offset))
      (constant (format nil "Const~D" offset))
      (immediate-constant "Immed"))))

(defun primitive-type-indirect-cell-type (ptype)
  (declare (ignore ptype))
  nil)
