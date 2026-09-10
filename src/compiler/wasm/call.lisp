;;;; the VM definition of function call for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; The convention (doc/wasm-port/02-design.md, 2.4)
;;;;
;;;; Every Lisp function is a Wasm function of type () -> (i32). The
;;;; caller sets NARGS (a fixnum), the argument registers A0..A3 (further
;;;; arguments on the control stack in the callee's frame), LEXENV (the
;;;; function object), CODE (the callee's simple-fun, which the XEP turns
;;;; into its code object), OCFP (the caller's frame) and RA (the return
;;;; point descriptor), makes CFP the callee's frame and calls the
;;;; callee's table entry with CALL_INDIRECT. The callee returns 0 for a
;;;; single value in A0, or 1 for multiple values: NARGS values, the
;;;; first four in A0..A3, all of them on the stack from OCFP, CSP just
;;;; past them. Tail calls are RETURN_CALL_INDIRECT with the frame passed
;;;; on. Local calls within a component are direct CALLs of the callee's
;;;; Wasm function (CALL-LABEL, resolved by the function assembler); tail
;;;; local calls are jumps to the callee's first block, which the
;;;; function assembler turns into RETURN_CALL.

;;; The SC+OFFSET of the argument-count register, for the debugger's
;;; report of an invalid-arg-count error.
(defconstant arg-count-sc (make-sc+offset any-reg-sc-number nargs-offset))
(defconstant closure-sc (make-sc+offset descriptor-reg-sc-number lexenv-offset))

;;;; Interfaces to IR2 conversion:

;;; The return-point descriptor of a call is passed in RA (see vm.lisp).
(defun make-return-pc-passing-location ()
  (make-wired-tn *fixnum-primitive-type* any-reg-sc-number ra-offset))

(defun make-old-fp-passing-location ()
  (make-wired-tn *fixnum-primitive-type* any-reg-sc-number ocfp-offset))

(defconstant old-fp-passing-offset
  (make-sc+offset descriptor-reg-sc-number ocfp-offset))

;;; Make the TNs used to hold OLD-FP and RETURN-PC within the current
;;; function. We treat these specially so that the debugger can find them
;;; at a known location.
(defun make-old-fp-save-location (env)
  (specify-save-tn
   (environment-debug-live-tn (make-normal-tn *fixnum-primitive-type*) env)
   (make-wired-tn *fixnum-primitive-type* control-stack-sc-number ocfp-save-offset)))

(defun make-return-pc-save-location (env)
  (let ((ptype *fixnum-primitive-type*))
    (specify-save-tn
     (environment-debug-live-tn
      (make-wired-tn *fixnum-primitive-type* any-reg-sc-number ra-offset)
      env)
     (make-wired-tn ptype control-stack-sc-number ra-save-offset))))

;;; Make a TN for the standard argument count passing location.
(defun make-arg-count-location ()
  (make-wired-tn *fixnum-primitive-type* any-reg-sc-number nargs-offset))

;;; This function is called by the ENTRY-ANALYZE phase, allowing
;;; VM-dependent initialization of the IR2-COMPONENT structure. We push
;;; placeholder entries in the CONSTANTS to leave room for additional
;;; noise in the code object header.
(defun select-component-format (component)
  (declare (type component component))
  (dotimes (i code-constants-offset)
    (vector-push-extend nil
                        (ir2-component-constants (component-info component))))
  (values))

;;; Emit the label of an IR2 block. Every block becomes an arm of the
;;; function's dispatcher (see func-asm.lisp); no alignment, and no
;;; trampolines are needed since local calls are direct.
(defun emit-block-header (start-label trampoline-label fall-thru-p alignp)
  (declare (ignore fall-thru-p alignp))
  (when trampoline-label
    (emit-label trampoline-label))
  (emit-label start-label))

;;;; Frame hackery:

;;; Used for setting up the Old-FP in local call.
(define-vop (current-fp)
  (:results (val :scs (any-reg)))
  (:generator 1
    (move val cfp-tn)))

;;; Used for computing the caller's NFP for use in known-values return.
(define-vop (compute-old-nfp)
  (:results (val :scs (any-reg)))
  (:vop-var vop)
  (:generator 1
    (let ((nfp (current-nfp-tn vop)))
      (when nfp
        (store-reg val
          (emit-reg-plus nfp (bytes-needed-for-non-descriptor-stack-frame)))))))

;;; Accessing a slot from an earlier stack frame is definite hackery.
(define-vop (ancestor-frame-ref)
  (:args (frame-pointer :scs (descriptor-reg))
         (variable-home-tn :load-if nil))
  (:results (value :scs (descriptor-reg any-reg)))
  (:policy :fast-safe)
  (:generator 4
    (aver (sc-is variable-home-tn control-stack))
    (load-frame-word value frame-pointer (tn-offset variable-home-tn))))

(define-vop (ancestor-frame-set)
  (:args (frame-pointer :scs (descriptor-reg))
         (value :scs (descriptor-reg any-reg)))
  (:results (variable-home-tn :load-if nil))
  (:generator 4
    (aver (sc-is variable-home-tn control-stack))
    (store-frame-word value frame-pointer (tn-offset variable-home-tn))))

;;; The XEP entry: each entry of a component is one Wasm function whose
;;; code starts at START-LAB (see func-asm.lisp). On entry the caller has
;;; set CFP to the new frame, OCFP to its own frame, NARGS, the argument
;;; registers, LEXENV, RA and CODE, the latter holding the callee's
;;; simple-fun; it becomes the code object here (the simple-fun header
;;; data is the word offset from the code object). There is no function
;;; header in the code.
(define-vop (xep-allocate-frame)
  (:info start-lab)
  (:generator 1
    ;; the simple-fun header, aligned as on every other target: the entry
    ;; label points at it, the executable code starts after it
    (emit-alignment n-lowtag-bits)
    (emit-label start-lab)
    (inst simple-fun-header-word)
    (inst .skip (* (1- simple-fun-insts-offset) n-word-bytes))
    (store-reg code-tn
      (load-reg code-tn)
      (load-reg code-tn)
      (emit-load-word (- fun-pointer-lowtag))
      (inst i32.const n-widetag-bits)
      (inst i32.shr_u)
      (inst i32.const word-shift)
      (inst i32.shl)
      (inst i32.sub)
      (inst i32.const (- other-pointer-lowtag fun-pointer-lowtag))
      (inst i32.add))))

;;; The safe point at every entry: the runtime's PENDING-INTERRUPT when
;;; the thread's interrupt-pending word is set (2.7; also the entry
;;; trace) or the frame just allocated ends past the control-stack
;;; limit (the guard, see +THREAD-CONTROL-STACK-LIMIT-OFFSET+). Emitted
;;; once the frame is set up, by XEP-SETUP-SP or, for entries with &MORE
;;; arguments, by COPY-MORE-ARG.
(defun emit-safe-point ()
  (let ((skip (gen-label)))
    (inst global.get +thread-global+)
    (inst i32.load +thread-interrupt-pending-offset+)
    (inst global.get +thread-global+)
    (inst i32.load +thread-control-stack-limit-offset+)
    (load-reg csp-tn)
    (inst i32.lt_u)                     ; limit < CSP
    (inst i32.or)
    (inst i32.eqz)
    (inst jump-if skip)
    (inst call +import-pending-interrupt+)
    (emit-label skip)))

;;; The control-stack guard alone, for the frames local calls allocate
;;; (ALLOCATE-FRAME): a self-recursive local function never passes an
;;; entry point.
(defun emit-stack-check ()
  (let ((skip (gen-label)))
    (inst global.get +thread-global+)
    (inst i32.load +thread-control-stack-limit-offset+)
    (load-reg csp-tn)
    (inst i32.ge_u)                     ; limit >= CSP: fine
    (inst jump-if skip)
    (inst call +import-pending-interrupt+)
    (emit-label skip)))

(define-vop (xep-setup-sp)
  (:vop-var vop)
  (:generator 1
    (store-reg csp-tn
      (emit-reg-plus cfp-tn (* n-word-bytes (sb-allocated-size 'control-stack))))
    (let ((nfp (current-nfp-tn vop)))
      (when nfp
        (store-reg nsp-tn
          (emit-reg-plus nsp-tn (- (bytes-needed-for-non-descriptor-stack-frame))))
        (move nfp nsp-tn)))
    (emit-safe-point)))

(define-vop (allocate-frame)
  (:results (res :scs (any-reg))
            (nfp :scs (any-reg)))
  (:info callee)
  (:generator 2
    (move res csp-tn)
    (store-reg csp-tn
      (emit-reg-plus csp-tn (* n-word-bytes (sb-allocated-size 'control-stack))))
    (emit-stack-check)
    (when (ir2-environment-number-stack-p callee)
      (store-reg nsp-tn
        (emit-reg-plus nsp-tn (- (bytes-needed-for-non-descriptor-stack-frame))))
      (move nfp nsp-tn))))

;;; Allocate a partial frame for passing stack arguments in a full call.
;;; NARGS is the number of arguments passed. If no stack arguments are
;;; passed, then we don't have to do anything.
(define-vop (allocate-full-call-frame)
  (:info nargs)
  (:results (res :scs (any-reg)))
  (:generator 2
    (when (> nargs register-arg-count)
      (move res csp-tn)
      (store-reg csp-tn
        (emit-reg-plus csp-tn (* nargs n-word-bytes))))))

;;; Emit code needed at the return-point from an unknown-values call for
;;; a fixed number of values. VALUES is the head of the TN-REF list for
;;; the locations that the values are to be received into. NVALS is the
;;; number of values that are to be received (should equal the length of
;;; VALUES). The callee's result flag (0 single, 1 multiple) is on the
;;; operand stack.
;;;
;;; In the single-value case A0 holds the value and the other registers
;;; are defaulted to NIL. In the multiple-values case the values start at
;;; OCFP with the first four also in A0..A3 (the callee defaulted the
;;; registers past the count), and CSP is reset past the values.
(defun default-unknown-values (vop values nvals move-temp)
  (declare (type (or tn-ref null) values)
           (type unsigned-byte nvals) (type tn move-temp))
  (let ((expecting-values-on-stack (> nvals register-arg-count))
        (multiple (gen-label))
        (done (gen-label)))
    (note-this-location vop (if (<= nvals 1)
                                :single-value-return
                                :unknown-return))
    (inst jump-if multiple)
    ;; a single value: default the other register values
    (when values
      (do ((i 1 (1+ i))
           (val (tn-ref-across values) (tn-ref-across val)))
          ((= i (min nvals register-arg-count)))
        (unless (eq (tn-kind (tn-ref-tn val)) :unused)
          (load-immediate-word (tn-ref-tn val) nil-value))))
    (cond ((not expecting-values-on-stack)
           (inst jump done)
           (emit-label multiple)
           (move csp-tn ocfp-tn)
           (emit-label done))
          (t
           ;; make it look like a one-value multiple return
           (move ocfp-tn csp-tn)
           (load-immediate-word nargs-tn (fixnumize 1))
           (emit-label multiple)
           ;; value I (I >= REGISTER-ARG-COUNT) is at OCFP[I] when NARGS > I
           (do ((i register-arg-count (1+ i))
                (val (do ((i 0 (1+ i))
                          (val values (tn-ref-across val)))
                         ((= i register-arg-count) val))
                     (tn-ref-across val)))
               ((null val))
             (let ((tn (tn-ref-tn val)))
               (unless (eq (tn-kind tn) :unused)
                 (let ((none (gen-label))
                       (defaulted (gen-label)))
                   (load-reg nargs-tn)
                   (inst i32.const (fixnumize i))
                   (inst i32.le_s)
                   (inst jump-if none)
                   (sc-case tn
                     (control-stack
                      (loadw move-temp ocfp-tn i)
                      (store-stack-tn tn move-temp))
                     (t
                      (loadw tn ocfp-tn i)))
                   (inst jump defaulted)
                   (emit-label none)
                   (sc-case tn
                     (control-stack
                      (load-immediate-word move-temp nil-value)
                      (store-stack-tn tn move-temp))
                     (t
                      (load-immediate-word tn nil-value)))
                   (emit-label defaulted)))))
           (move csp-tn ocfp-tn))))
  (values))

;;;; Unknown values receiving:

;;; Emit code needed at the return point for an unknown-values call for
;;; an arbitrary number of values, with the callee's result flag on the
;;; operand stack.
;;;
;;; We do the single and non-single cases with no shared code: there
;;; doesn't seem to be any potential overlap, and receiving a single
;;; value is more important efficiency-wise.
;;;
;;; When there is a single value, we just push it on the stack, returning
;;; the old SP and 1. When there are multiple values, the values are
;;; already on the stack from ARGS (OCFP); we store the register values
;;; into their slots and return ARGS and NARGS.
(defun receive-unknown-values (args nargs start count)
  (declare (type tn args nargs start count))
  (let ((multiple (gen-label))
        (done (gen-label)))
    (inst jump-if multiple)
    (move start csp-tn)
    (store-reg csp-tn (emit-reg-plus csp-tn n-word-bytes))
    (storew (first *register-arg-tns*) start 0)
    (load-immediate-word count (fixnumize 1))
    (inst jump done)
    (emit-label multiple)
    (do ((arg *register-arg-tns* (rest arg))
         (i 0 (1+ i)))
        ((null arg))
      (storew (first arg) args i))
    (move start args)
    (move count nargs)
    (emit-label done)))

;;; VOP that can be inherited by unknown values receivers. The main thing
;;; this handles is allocation of the result temporaries.
(define-vop (unknown-values-receiver)
  (:results (start :scs (any-reg))
            (count :scs (any-reg)))
  (:temporary (:sc descriptor-reg :offset ocfp-offset
                   :from :eval :to (:result 0))
              values-start)
  (:temporary (:sc any-reg :offset nargs-offset
               :from :eval :to (:result 1))
              nvals))

;;;; Local call with unknown values convention return:

;;; Non-TR local call for a fixed number of values passed according to
;;; the unknown values convention.
;;;
;;; ARGS are the argument passing locations, which are specified only to
;;; terminate their lifetimes in the caller.
;;;
;;; VALUES are the return value locations (wired to the standard passing
;;; locations).
;;;
;;; SAVE is the save info, which we can ignore since saving has been done.
;;; TARGET is the label of the callee's first block; the function
;;; assembler resolves the direct call.
(define-vop (call-local)
  (:args (fp)
         (nfp)
         (args :more t))
  (:results (values :more t))
  (:save-p t)
  (:move-args :local-call)
  (:vop-var vop)
  (:temporary (:scs (descriptor-reg) :from (:eval 0)) move-temp)
  (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
  ;; the callee may end in a full tail call, whose callee returns here
  ;; with its own code object in CODE (as after any full call)
  (:temporary (:sc control-stack :offset code-save-offset) code-save)
  (:temporary (:sc any-reg :offset ocfp-offset :from (:eval 0)) ocfp)
  (:ignore arg-locs args ocfp)
  (:info arg-locs callee target nvals)
  (:generator 5
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (store-stack-tn nfp-save cur-nfp))
      (store-stack-tn code-save code-tn)
      (let ((callee-nfp (callee-nfp-tn callee)))
        (when callee-nfp
          (maybe-load-stack-tn callee-nfp nfp)))
      (maybe-load-stack-tn cfp-tn fp)
      (note-this-location vop :call-site)
      (inst call-label target)
      (load-stack-tn code-tn code-save)
      (default-unknown-values vop values nvals move-temp)
      (when cur-nfp
        (load-stack-tn cur-nfp nfp-save)))))

;;; Non-TR local call for a variable number of return values passed
;;; according to the unknown values convention. The results are the
;;; start of the values glob and the number of values received.
(define-vop (multiple-call-local unknown-values-receiver)
  (:args (fp)
         (nfp)
         (args :more t))
  (:info save callee target)
  (:save-p t)
  (:move-args :local-call)
  (:ignore args save)
  (:vop-var vop)
  (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
  (:temporary (:sc control-stack :offset code-save-offset) code-save)
  (:generator 20
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (store-stack-tn nfp-save cur-nfp))
      (store-stack-tn code-save code-tn)
      (let ((callee-nfp (callee-nfp-tn callee)))
        (when callee-nfp
          (maybe-load-stack-tn callee-nfp nfp)))
      (maybe-load-stack-tn cfp-tn fp)
      (note-this-location vop :call-site)
      (inst call-label target)
      (note-this-location vop :unknown-return)
      (load-stack-tn code-tn code-save)
      (receive-unknown-values values-start nvals start count)
      (when cur-nfp
        (load-stack-tn cur-nfp nfp-save)))))

;;;; Local call with known values return:

;;; Non-TR local call with known return locations. Known-value return
;;; works just like argument passing in local call.
;;;
;;; Note that we can't use the obvious morphing of the local call vop:
;;; the values are in wired locations, and the known return is a plain
;;; Wasm return whose result flag we drop.
(define-vop (known-call-local)
  (:args (fp)
         (nfp)
         (args :more t))
  (:results (res :more t))
  (:info save callee target)
  (:ignore args res save)
  (:save-p t)
  (:move-args :local-call)
  (:vop-var vop)
  (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
  (:generator 5
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (store-stack-tn nfp-save cur-nfp))
      (let ((callee-nfp (callee-nfp-tn callee)))
        (when callee-nfp
          (maybe-load-stack-tn callee-nfp nfp)))
      (maybe-load-stack-tn cfp-tn fp)
      (note-this-location vop :call-site)
      (inst call-label target)
      (inst drop)
      (note-this-location vop :known-return)
      (when cur-nfp
        (load-stack-tn cur-nfp nfp-save)))))

;;; Return from known values call. We receive the return locations as
;;; arguments to terminate their lifetimes in the returning function. We
;;; restore FP and CSP and return from the Wasm function; the result
;;; flag is not looked at by a known caller.
(define-vop (known-return)
  (:args (old-fp :target old-fp-temp)
         (return-pc)
         (values :more t))
  (:temporary (:sc any-reg :from (:argument 0)) old-fp-temp)
  (:info val-locs)
  (:ignore val-locs values return-pc)
  (:move-args :known-return)
  (:vop-var vop)
  (:generator 6
    (maybe-load-stack-tn old-fp-temp old-fp)
    (move csp-tn cfp-tn)
    (clear-number-stack vop)
    (move cfp-tn old-fp-temp)
    (inst i32.const 0)
    (inst return)))

;;;; Full call:
;;;;
;;;; There is something of a cross-product effect with full calls.
;;;; Different versions are used depending on whether a variable number
;;;; of arguments are passed, whether or not the argument count is known
;;;; at compile time, the return convention, and whether the call is
;;;; through a fdefn (named), a function object or a static function.

;;; FUNCTION holds the callee's simple-fun: pass it in CODE and call
;;; its table entry, the SELF slot of the simple-fun. With INDEX, the
;;; table entry is already in the register FUNCTION and CODE holds the
;;; function object (a named call: the XEP finds the simple-fun in a
;;; closure itself, and the closure trampoline finds it in the fdefn).
(defun emit-full-call (function tail-p &key index)
  (cond (index
         (load-reg function))
        (t
         (move code-tn function)
         (load-reg function)
         (emit-load-word (- (ash simple-fun-self-slot word-shift) fun-pointer-lowtag))))
  (if tail-p
      (inst return_call_indirect +lisp-function-type-index+)
      (inst call_indirect +lisp-function-type-index+)))

;;; FUNCTION := the simple-fun of the function object in LEXENV: the
;;; object itself, the fun slot of a closure, or the function slot of a
;;; funcallable instance (which may hold a closure). A funcallable
;;; instance is entered as the function it holds: LEXENV becomes that
;;; function, as the trampoline of the machine-code backends arranges,
;;; so that a closure in the slot finds its values.
(defun emit-function-object-entry (lexenv function)
  (let ((loop (gen-label))
        (done (gen-label))
        (closure (gen-label)))
    (move function lexenv)
    (emit-label loop)
    (load-reg function)
    (emit-load-sized 1 nil (- fun-pointer-lowtag))
    (inst i32.const simple-fun-widetag)
    (inst i32.eq)
    (inst jump-if done)
    (load-reg function)
    (emit-load-sized 1 nil (- fun-pointer-lowtag))
    (inst i32.const closure-widetag)
    (inst i32.eq)
    (inst jump-if closure)
    ;; a funcallable instance: call the function it holds
    (loadw function function funcallable-instance-function-slot fun-pointer-lowtag)
    (move lexenv function)
    (inst jump loop)
    (emit-label closure)
    (loadw function function closure-fun-slot fun-pointer-lowtag)
    (inst jump loop)
    (emit-label done)))

;;; This macro helps in the definition of full call VOPs by avoiding code
;;; replication in defining the cross-product VOPs.
;;;
;;; NAME is the name of the VOP to define.
;;;
;;; NAMED is true if the first argument is a symbol whose global function
;;; definition is to be called; :DIRECT for a static function.
;;;
;;; RETURN is either :FIXED, :UNKNOWN or :TAIL, indicating the return
;;; convention.
;;;
;;; VARIABLE is true if the number of arguments is unknown at compile
;;; time, in which case the arguments start at NEW-FP and end at CSP.
(defmacro define-full-call (name named return variable)
  (aver (not (and variable (eq return :tail))))
  (let ((register-arg-names (loop repeat register-arg-count
                                  collect (gensym))))
    `(define-vop (,name
                  ,@(when (eql return :unknown) '(unknown-values-receiver)))
       (:args
        ,@(unless (eq return :tail)
            '((new-fp :scs (any-reg) :to :eval)))
        ,@(case named
            ((nil)
             '((arg-fun :target lexenv)))
            (:direct)
            (t '((name :target name-pass))))
        ,@(when (eq return :tail)
            '((old-fp :target old-fp-pass)
              (return-pc :target return-pc-pass)))
        ,@(unless variable
            '((args :more t :scs (descriptor-reg control-stack)))))
       ,@(when (eq return :fixed)
           '((:results (values :more t))))
       (:save-p ,(if (eq return :tail) :compute-only t))
       ,@(unless (or (eq return :tail) variable)
           '((:move-args :full-call)))
       (:vop-var vop)
       (:info
        ,@(unless (or variable (eq return :tail)) '(arg-locs))
        ,@(unless variable '(nargs))
        ,@(when (eq named :direct) '(fun))
        ,@(when (eq return :fixed) '(nvals))
        step-instrumenting)
       (:ignore ,@(unless (or variable (eq return :tail)) '(arg-locs))
                ,@(unless variable '(args))
                step-instrumenting)
       (:temporary (:sc descriptor-reg
                    :offset ocfp-offset
                    :from (:argument 1)
                    ,@(unless (eq return :fixed)
                        '(:to :eval)))
                   old-fp-pass)
       (:temporary (:sc any-reg
                    :offset ra-offset
                    :from (:argument ,(if (eq return :tail) 2 1))
                    :to :eval)
                   return-pc-pass)
       ,@(unless (eq named :direct)
           `((:temporary (:sc descriptor-reg :offset lexenv-offset
                          :from (:argument ,(if (eq return :tail) 0 1))
                          :to :eval)
                         ,(if named 'name-pass 'lexenv))))
       (:temporary (:scs (descriptor-reg) :offset l0-offset
                         :to :eval)
                   function)
       (:temporary (:sc any-reg :offset nargs-offset :to
                        ,(if (eq return :fixed)
                             :save
                             :eval))
                   nargs-pass)
       ,@(when variable
           (mapcar #'(lambda (name offset)
                       `(:temporary (:sc descriptor-reg
                                     :offset ,offset
                                     :to :eval)
                                    ,name))
                   register-arg-names *register-arg-offsets*))
       ,@(when (eq return :fixed)
           '((:temporary (:scs (descriptor-reg) :from :eval) move-temp)))
       ,@(unless (eq return :tail)
           '((:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
             ;; the callee's XEP sets CODE to its own code object and nothing
             ;; on this target restores it on return: save ours across the call
             (:temporary (:sc control-stack :offset code-save-offset) code-save)))
       (:generator ,(+ (if named 5 0)
                       (if variable 19 1)
                       (if (eq return :tail) 0 10)
                       15
                       (if (eq return :unknown) 25 0))
         (let ((cur-nfp (current-nfp-tn vop)))
           ;; our code object, before CODE is used to pass the callee's
           ;; function; reloaded after the call
           ,@(unless (eq return :tail)
               '((store-stack-tn code-save code-tn)))
           ;; the function to call: FUNCTION := its simple-fun
           ,@(case named
               ((t)
                `((sc-case name
                    (descriptor-reg (move name-pass name))
                    (control-stack (load-stack-tn name-pass name))
                    (constant (load-constant vop name name-pass)))
                  (loadw code-tn name-pass fdefn-fun-slot other-pointer-lowtag)
                  (loadw function name-pass fdefn-raw-addr-slot other-pointer-lowtag)))
               ((nil)
                `((sc-case arg-fun
                    (descriptor-reg (move lexenv arg-fun))
                    (control-stack (load-stack-tn lexenv arg-fun))
                    (constant (load-constant vop arg-fun lexenv)))
                  (emit-function-object-entry lexenv function)))
               (:direct
                `((store-reg code-tn
                    (inst i32.const (+ nil-value (static-fun-offset fun)
                                       (* (- fdefn-fun-slot fdefn-raw-addr-slot) n-word-bytes)))
                    (inst i32.load 0))
                  (store-reg function
                    (inst i32.const (+ nil-value (static-fun-offset fun)))
                    (inst i32.load 0)))))
           ;; the argument count and, for a variable call, the register
           ;; arguments (the stack arguments are in place from NEW-FP)
           ,@(if variable
                 `((store-reg nargs-pass
                     (load-reg csp-tn)
                     (load-reg new-fp)
                     (inst i32.sub))
                   ,@(loop for name in register-arg-names
                           for i from 0
                           collect `(loadw ,name new-fp ,i)))
                 `((load-immediate-word nargs-pass (fixnumize nargs))))
           ;; frames, the return point and the number stack
           ,@(if (eq return :tail)
                 `((sc-case old-fp
                     (any-reg (move old-fp-pass old-fp))
                     (control-stack (load-stack-tn old-fp-pass old-fp)))
                   (sc-case return-pc
                     (any-reg (move return-pc-pass return-pc))
                     (control-stack (load-stack-tn return-pc-pass return-pc)))
                   (when cur-nfp
                     (store-reg nsp-tn
                       (emit-reg-plus cur-nfp (bytes-needed-for-non-descriptor-stack-frame)))))
                 `((when cur-nfp
                     (store-stack-tn nfp-save cur-nfp))
                   (move old-fp-pass cfp-tn)
                   (load-immediate-word return-pc-pass 0)
                   ,(if variable
                        '(move cfp-tn new-fp)
                        '(if (> nargs register-arg-count)
                             (move cfp-tn new-fp)
                             (move cfp-tn csp-tn)))))
           (note-this-location vop :call-site)
           (emit-full-call function ,(eq return :tail) :index ,(not (null named)))
           ,@(ecase return
               (:fixed
                '((load-stack-tn code-tn code-save)
                  (default-unknown-values vop values nvals move-temp)
                  (when cur-nfp
                    (load-stack-tn cur-nfp nfp-save))))
               (:unknown
                '((note-this-location vop :unknown-return)
                  (load-stack-tn code-tn code-save)
                  (receive-unknown-values values-start nvals start count)
                  (when cur-nfp
                    (load-stack-tn cur-nfp nfp-save))))
               (:tail)))))))

(define-full-call call nil :fixed nil)
(define-full-call call-named t :fixed nil)
(define-full-call static-call-named :direct :fixed nil)
(define-full-call multiple-call nil :unknown nil)
(define-full-call multiple-call-named t :unknown nil)
(define-full-call static-multiple-call-named :direct :unknown nil)
(define-full-call tail-call nil :tail nil)
(define-full-call tail-call-named t :tail nil)
(define-full-call static-tail-call-named :direct :tail nil)

(define-full-call call-variable nil :fixed t)
(define-full-call multiple-call-variable nil :unknown t)

;;; Defined separately, since needs special code that BLT's the arguments
;;; down: the arguments are on the stack from ARGS to CSP and are moved
;;; into the register arguments and the callee's frame at CFP, then the
;;; function is tail-called.
(define-vop (tail-call-variable)
  (:args
   (args-arg :scs (any-reg) :target args)
   (function-arg :scs (descriptor-reg) :target lexenv)
   (old-fp-arg :scs (any-reg) :target old-fp)
   (ra-arg :scs (any-reg) :target ra))
  (:temporary (:sc any-reg :offset nl0-offset :from (:argument 0)) args)
  (:temporary (:sc any-reg :offset lexenv-offset :from (:argument 1)) lexenv)
  (:temporary (:sc any-reg :offset ocfp-offset :from (:argument 2)) old-fp)
  (:temporary (:sc any-reg :offset ra-offset :from (:argument 3)) ra)
  (:temporary (:sc any-reg :offset nl1-offset) src)
  (:temporary (:sc any-reg :offset nl2-offset) dst)
  (:temporary (:sc any-reg :offset nl3-offset) count)
  (:temporary (:sc descriptor-reg :offset l0-offset) function)
  (:vop-var vop)
  (:generator 75
    (let ((loop (gen-label))
          (done (gen-label)))
      (move args args-arg)
      (move lexenv function-arg)
      (move old-fp old-fp-arg)
      (move ra ra-arg)
      (clear-number-stack vop)
      ;; NARGS, as a fixnum, is the byte size of the argument area
      (store-reg nargs-tn
        (load-reg csp-tn)
        (load-reg args)
        (inst i32.sub))
      (loop for an in *register-arg-tns*
            for i from 0
            do (loadw an args i))
      ;; the stack arguments move down to the frame
      (store-reg count
        (load-reg nargs-tn)
        (inst i32.const (* register-arg-count n-word-bytes))
        (inst i32.sub))
      (store-reg src (emit-reg-plus args (* register-arg-count n-word-bytes)))
      (store-reg dst (emit-reg-plus cfp-tn (* register-arg-count n-word-bytes)))
      (emit-label loop)
      (load-reg count)
      (inst i32.const 0)
      (inst i32.le_s)
      (inst jump-if done)
      (loadw function src)
      (storew function dst)
      (store-reg src (emit-reg-plus src n-word-bytes))
      (store-reg dst (emit-reg-plus dst n-word-bytes))
      (store-reg count (emit-reg-plus count (- n-word-bytes)))
      (inst jump loop)
      (emit-label done)
      (emit-function-object-entry lexenv function)
      (emit-full-call function t))))

;;;; Unknown values return:

;;; CLEAR-NUMBER-STACK is in macros.lisp.

;;; Return a single value. The frame is discarded and the function
;;; returns 0, the "single value in A0" flag of the convention.
(define-vop (return-single)
  (:args (old-fp :scs (any-reg))
         (return-pc :scs (any-reg))
         (value))
  (:ignore value return-pc)
  (:vop-var vop)
  (:generator 6
    (clear-number-stack vop)
    (move csp-tn cfp-tn)
    (move cfp-tn old-fp)
    (inst i32.const 0)
    (inst return)))

;;; Do unknown-values return of a fixed number of values. The VALUES are
;;; required to be set up in the standard passing locations. NVALS is the
;;; number of values returned.
;;;
;;; The values are on the stack from CFP (the register values were also
;;; stored there by the move-args of the return); OCFP becomes the values
;;; pointer, NARGS the count, CSP the end of the values, and the function
;;; returns 1.
(define-vop (return)
  (:args (old-fp :scs (any-reg))
         (return-pc :scs (any-reg))
         (values :more t))
  (:ignore values return-pc)
  (:info nvals)
  ;; the registers written here are declared so that OLD-FP (any
  ;; any-reg) is never packed in one of them: it was once packed in NARGS,
  ;; and the value count overwrote the frame pointer being returned to
  (:temporary (:sc any-reg :offset nargs-offset) nargs)
  (:temporary (:sc any-reg :offset ocfp-offset) val-ptr)
  (:vop-var vop)
  (:generator 6
    (when (= nvals 1)
      ;; This is handled in RETURN-SINGLE.
      (error "nvalues is 1"))
    (clear-number-stack vop)
    (move val-ptr cfp-tn)
    (load-immediate-word nargs (fixnumize nvals))
    (move cfp-tn old-fp)
    (store-reg csp-tn (emit-reg-plus val-ptr (* nvals n-word-bytes)))
    ;; default any argument register that was not supplied
    (loop for i from nvals below register-arg-count
          do (load-immediate-word (nth i *register-arg-tns*) nil-value))
    (inst i32.const 1)
    (inst return)))

;;; Do unknown-values return of an arbitrary number of values (passed on
;;; the stack from VALS-ARG, NVALS-ARG of them). The values are copied to
;;; the frame at CFP (the register values loaded and defaulted) and the
;;; function returns as RETURN does; one value is returned as
;;; RETURN-SINGLE does.
(define-vop (return-multiple)
  (:args (old-fp-arg :scs (any-reg) :target old-fp)
         (return-pc :scs (any-reg))
         (vals-arg :scs (any-reg) :target vals)
         (nvals-arg :scs (any-reg) :target nvals))
  (:temporary (:sc any-reg :offset nl1-offset :from (:argument 0)) old-fp)
  (:temporary (:sc any-reg :offset nl0-offset :from (:argument 2)) vals)
  (:temporary (:sc any-reg :offset nargs-offset :from (:argument 3)) nvals)
  (:temporary (:sc any-reg :offset nl2-offset) count)
  (:temporary (:sc any-reg :offset nl3-offset) dst)
  (:temporary (:scs (descriptor-reg) :offset l0-offset) temp)
  (:ignore return-pc)
  (:vop-var vop)
  (:generator 13
    (let ((single (gen-label))
          (loop (gen-label))
          (done (gen-label)))
      (clear-number-stack vop)
      (move old-fp old-fp-arg)
      (move vals vals-arg)
      (move nvals nvals-arg)
      (load-reg nvals)
      (inst i32.const (fixnumize 1))
      (inst i32.eq)
      (inst jump-if single)
      ;; the register values, NIL past the count
      (loop for an in *register-arg-tns*
            for i from 0
            do (let ((have (gen-label))
                     (next (gen-label)))
                 (load-reg nvals)
                 (inst i32.const (fixnumize i))
                 (inst i32.gt_s)
                 (inst jump-if have)
                 (load-immediate-word an nil-value)
                 (inst jump next)
                 (emit-label have)
                 (loadw an vals i)
                 (emit-label next)))
      ;; the stack values move down to the frame
      (store-reg count
        (load-reg nvals)
        (inst i32.const (fixnumize register-arg-count))
        (inst i32.sub))
      (store-reg vals (emit-reg-plus vals (* register-arg-count n-word-bytes)))
      (store-reg dst (emit-reg-plus cfp-tn (* register-arg-count n-word-bytes)))
      (emit-label loop)
      (load-reg count)
      (inst i32.const 0)
      (inst i32.le_s)
      (inst jump-if done)
      (loadw temp vals)
      (storew temp dst)
      (store-reg vals (emit-reg-plus vals n-word-bytes))
      (store-reg dst (emit-reg-plus dst n-word-bytes))
      (store-reg count (emit-reg-plus count (- (fixnumize 1))))
      (inst jump loop)
      (emit-label done)
      (move ocfp-tn cfp-tn)
      (move cfp-tn old-fp)
      (store-reg csp-tn
        (load-reg ocfp-tn)
        (load-reg nvals)
        (inst i32.add))
      (inst i32.const 1)
      (inst return)
      ;; a single value
      (emit-label single)
      (loadw (first *register-arg-tns*) vals 0)
      (move csp-tn cfp-tn)
      (move cfp-tn old-fp)
      (inst i32.const 0)
      (inst return))))

;;;; XEP hackery:

;;; Get the lexical environment from its passing location.
(define-vop (setup-closure-environment)
  (:temporary (:sc descriptor-reg :offset lexenv-offset :target closure
               :to (:result 0))
              lexenv)
  (:results (closure :scs (descriptor-reg)))
  (:info label)
  (:ignore label)
  (:generator 6
    (move closure lexenv)))

;;; Copy a &MORE arg from the argument area to the end of the current
;;; frame. FIXED is the number of non-&MORE arguments.
(define-vop (copy-more-arg)
  (:temporary (:sc any-reg :offset nl0-offset) result)
  (:temporary (:sc any-reg :offset nl1-offset) count)
  (:temporary (:sc any-reg :offset nl3-offset) dest)
  (:temporary (:sc descriptor-reg :offset l0-offset) temp)
  (:vop-var vop)
  (:info fixed)
  (:generator 20
    (let ((loop (gen-label))
          (do-regs (gen-label))
          (done (gen-label))
          (delta (- (sb-allocated-size 'control-stack) fixed)))
      ;; RESULT is where the &MORE arguments go: the end of the frame
      (store-reg result
        (emit-reg-plus cfp-tn (* n-word-bytes (sb-allocated-size 'control-stack))))
      (cond ((zerop fixed)
             (store-reg dest
               (load-reg result)
               (load-reg nargs-tn)
               (inst i32.add))
             (move csp-tn dest)
             (load-reg nargs-tn)
             (inst i32.eqz)
             (inst jump-if done))
            (t
             (store-reg count
               (load-reg nargs-tn)
               (inst i32.const (fixnumize fixed))
               (inst i32.sub))
             (let ((skip (gen-label)))
               (load-reg count)
               (inst i32.const 0)
               (inst i32.gt_s)
               (inst jump-if skip)
               (move csp-tn result)
               (inst jump done)
               (emit-label skip))
             (store-reg dest
               (load-reg result)
               (load-reg count)
               (inst i32.add))
             (when (>= delta 0)
               (move csp-tn dest))))
      (when (< fixed register-arg-count)
        (store-reg result
          (emit-reg-plus result (* (- register-arg-count fixed) n-word-bytes))))
      (emit-label loop)
      (let ((done (gen-label)))
        (cond ((zerop delta)
               )
              ((plusp delta)
               ;; move the stack arguments up, from the end
               (load-reg result)
               (load-reg dest)
               (inst i32.ge_u)
               (inst jump-if do-regs)
               (load-frame-word temp dest (- (1+ delta)))
               (storew temp dest -1)
               (store-reg dest (emit-reg-plus dest (- n-word-bytes)))
               (inst jump loop))
              (t
               ;; move the stack arguments down, from the start
               (load-reg result)
               (load-reg dest)
               (inst i32.ge_u)
               (inst jump-if done)
               (loadw temp result (- delta))
               (storew temp result 0)
               (store-reg result (emit-reg-plus result n-word-bytes))
               (inst jump loop)
               (emit-label done)
               (move csp-tn dest))))
      (emit-label do-regs)
      (when (< fixed register-arg-count)
        (when (zerop fixed)
          (move count nargs-tn))
        (do ((i fixed (1+ i)))
            ((>= i register-arg-count))
          (load-reg count)
          (inst i32.eqz)
          (inst jump-if done)
          (store-reg count (emit-reg-plus count (- (fixnumize 1))))
          (store-frame-word (nth i *register-arg-tns*) cfp-tn
                            (+ (sb-allocated-size 'control-stack)
                               (- i fixed)))))
      (emit-label done)
      (let ((cur-nfp (current-nfp-tn vop)))
        (when cur-nfp
          (store-reg nsp-tn
            (emit-reg-plus nsp-tn (- (bytes-needed-for-non-descriptor-stack-frame))))
          (move cur-nfp nsp-tn)))
      ;; entries with &MORE arguments get no XEP-SETUP-SP: the safe point is here
      (emit-safe-point))))

;;; More args are stored consecutively on the stack, starting
;;; immediately at the context pointer. The context pointer is not
;;; typed, so the lowtag is 0.
(define-full-reffer more-arg * 0 0 (descriptor-reg any-reg) * %more-arg)

(define-vop (more-arg-or-nil)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :to (:result 1))
         (count :scs (any-reg) :to (:result 1)))
  (:info index)
  (:results (value :scs (descriptor-reg any-reg)))
  (:result-types *)
  (:generator 3
    (let ((done (gen-label)))
      (load-immediate-word value nil-value)
      (load-reg count)
      (inst i32.const (fixnumize index))
      (inst i32.le_s)
      (inst jump-if done)
      (loadw value object index)
      (emit-label done))))

;;; Turn more arg (context, count) into a list.
(define-vop ()
  (:args (context-arg :target context :scs (descriptor-reg))
         (count-arg :target count :scs (any-reg)))
  (:arg-types * tagged-num)
  (:temporary (:scs (any-reg) :from (:argument 0)) context)
  (:temporary (:scs (any-reg) :from (:argument 1)) count)
  (:temporary (:scs (descriptor-reg) :from :eval) temp)
  (:temporary (:scs (any-reg) :from :eval) dst)
  (:results (result :scs (descriptor-reg)))
  (:translate %listify-rest-args)
  (:policy :safe)
  (:generator 20
    (let ((loop (gen-label))
          (done (gen-label)))
      (move context context-arg)
      (move count count-arg)
      ;; Check to see if there are any arguments.
      (load-immediate-word result nil-value)
      (load-reg count)
      (inst i32.eqz)
      (inst jump-if done)
      ;; one cons (two words) per value: twice the fixnum count in bytes
      (emit-allocate dst
        (progn (load-reg count) (inst i32.const 1) (inst i32.shl) :pushed)
        list-pointer-lowtag :list t)
      (move result dst)
      (emit-label loop)
      ;; Grab one value and store it into the car of the current cons.
      (loadw temp context)
      (store-reg context (emit-reg-plus context n-word-bytes))
      (storew temp dst cons-car-slot list-pointer-lowtag)
      ;; Dec count, and if != zero, link the next cons and go back for more.
      (store-reg count (emit-reg-plus count (- (fixnumize 1))))
      (load-reg count)
      (inst i32.eqz)
      (inst jump-if done)
      (load-reg dst)
      (emit-store-word (- (ash cons-cdr-slot word-shift) list-pointer-lowtag)
        (emit-reg-plus dst (* cons-size n-word-bytes)))
      (store-reg dst (emit-reg-plus dst (* cons-size n-word-bytes)))
      (inst jump loop)
      (emit-label done)
      ;; NIL out the last cons (RESULT is NIL when there were no values).
      (let ((none (gen-label)))
        (load-reg result)
        (inst i32.const nil-value)
        (inst i32.eq)
        (inst jump-if none)
        (load-reg dst)
        (emit-store-word (- (ash cons-cdr-slot word-shift) list-pointer-lowtag)
          (inst i32.const nil-value))
        (emit-label none)))))

;;; Return the location and size of the &MORE arg glob created by
;;; COPY-MORE-ARG. SUPPLIED is the total number of arguments supplied
;;; (originally passed in NARGS). FIXED is the number of non-rest
;;; arguments.
;;;
;;; We must duplicate some of the work done by COPY-MORE-ARG, since at
;;; that time the environment is in a pretty brain-damaged state,
;;; preventing this info from being returned as values. What we do is
;;; compute supplied - fixed, and return a pointer that many words below
;;; the current stack top.
(define-vop ()
  (:policy :fast-safe)
  (:translate sb-c::%more-arg-context)
  (:args (supplied :scs (any-reg)))
  (:arg-types tagged-num (:constant fixnum))
  (:info fixed)
  (:results (context :scs (descriptor-reg))
            (count :scs (any-reg)))
  (:result-types t tagged-num)
  (:note "more-arg-context")
  (:generator 5
    (store-reg count
      (load-reg supplied)
      (inst i32.const (fixnumize fixed))
      (inst i32.sub))
    (store-reg context
      (load-reg csp-tn)
      (load-reg count)
      (inst i32.sub))))

(define-vop (verify-arg-count)
  (:policy :fast-safe)
  (:args (nargs :scs (any-reg)))
  (:info min max)
  (:vop-var vop)
  (:arg-types positive-fixnum (:constant t) (:constant t))
  (:save-p :compute-only)
  (:generator 3
    (let ((err-lab (generate-error-code vop 'invalid-arg-count-error nargs)))
      (flet ((check (constant compare)
               (load-reg nargs)
               (inst i32.const (fixnumize constant))
               (funcall compare)
               (inst jump-if err-lab)))
        (cond ((not min)
               (check max (lambda () (inst i32.ne))))
              ((not max)
               (check min (lambda () (inst i32.lt_s))))
              (t
               (check min (lambda () (inst i32.lt_s)))
               (check max (lambda () (inst i32.gt_s)))))))))

;;; Single stepping is a runtime facility (doc/wasm-port/02-design.md,
;;; 2.7); until then the instrumentation is a no-op.
(define-vop (step-instrument-before-vop)
  (:policy :fast-safe)
  (:vop-var vop)
  (:generator 3))
