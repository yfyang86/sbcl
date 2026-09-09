;;;; c-call VOPs for the WebAssembly target.
;;;;
;;;; Sprint 2 placeholder: the VOPs are written in the next sprint (see
;;;; doc/wasm-port/04-sprints.md). The file exists so that the backend
;;;; builds.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-VM")

;;; TN allocation for a call-out. Every argument is passed on the number
;;; stack (in word slots, doubles taking two); the CALL-OUT VOP of the
;;; foreign-call sprint pushes them on the Wasm operand stack from there.
;;; Integer and pointer results come back in NL0 (and NL1 for a second
;;; value), float results in float register 0.

(defstruct arg-state
  (stack-frame-size 0))

(defstruct (result-state (:copier nil))
  (num-results 0))

(defun result-reg-offset (slot)
  (ecase slot
    (0 nl0-offset)
    (1 nl1-offset)))

(defun stack-arg-tn (state prim-type stack-sc &optional (words 1))
  (let ((frame-size (arg-state-stack-frame-size state)))
    (setf (arg-state-stack-frame-size state) (+ frame-size words))
    (make-wired-tn* prim-type stack-sc frame-size)))

(define-alien-type-method (integer :arg-tn) (type state)
  (cond ((= (alien-type-bits type) 33)   ; the high half of a 64-bit integer, see below
         (stack-arg-tn state 'wasm-i64-high
                       (if (alien-integer-type-signed type)
                           signed-stack-sc-number
                           unsigned-stack-sc-number)))
        ((alien-integer-type-signed type)
         (stack-arg-tn state 'signed-byte-32 signed-stack-sc-number))
        (t
         (stack-arg-tn state 'unsigned-byte-32 unsigned-stack-sc-number))))

(define-alien-type-method (system-area-pointer :arg-tn) (type state)
  (declare (ignore type))
  (stack-arg-tn state 'system-area-pointer sap-stack-sc-number))

(define-alien-type-method (single-float :arg-tn) (type state)
  (declare (ignore type))
  (stack-arg-tn state 'single-float single-stack-sc-number))

(define-alien-type-method (double-float :arg-tn) (type state)
  (declare (ignore type))
  (stack-arg-tn state 'double-float double-stack-sc-number 2))

(define-alien-type-method (integer :result-tn) (type state)
  (let ((num-results (result-state-num-results state)))
    (setf (result-state-num-results state) (1+ num-results))
    (multiple-value-bind (ptype reg-sc)
        (cond ((= (alien-type-bits type) 33)   ; the high half of a 64-bit result
               (values 'wasm-i64-high (if (alien-integer-type-signed type)
                                          signed-reg-sc-number
                                          unsigned-reg-sc-number)))
              ((alien-integer-type-signed type)
               (values 'signed-byte-32 signed-reg-sc-number))
              (t
               (values 'unsigned-byte-32 unsigned-reg-sc-number)))
      (make-wired-tn* ptype reg-sc (result-reg-offset num-results)))))

(define-alien-type-method (system-area-pointer :result-tn) (type state)
  (declare (ignore type state))
  (make-wired-tn* 'system-area-pointer sap-reg-sc-number (result-reg-offset 0)))

(define-alien-type-method (single-float :result-tn) (type state)
  (declare (ignore type state))
  (make-wired-tn* 'single-float single-reg-sc-number 0))

(define-alien-type-method (double-float :result-tn) (type state)
  (declare (ignore type state))
  (make-wired-tn* 'double-float double-reg-sc-number 0))

(define-alien-type-method (values :result-tn) (type state)
  (let ((values (alien-values-type-values type)))
    (when (> (length values) 2)
      (error "Too many result values from c-call."))
    (mapcar (lambda (type)
              (invoke-alien-type-method :result-tn type state))
            values)))

(define-alien-type-method (integer :naturalize-gen) (type alien)
  (if (and (not (alien-integer-type-signed type))
           (= (alien-type-bits type) 32))
      `(logand ,alien ,(1- (ash 1 (alien-type-bits type))))
      alien))

;;;; 64-bit integers
;;;;
;;;; A C function taking or returning a 64-bit integer has an i64 in its
;;;; Wasm type, and the alien machinery of a 32-bit target has no 64-bit
;;;; representation. The transform below (after the arm backend's
;;;; long-long support) splits a 64-bit argument into two 32-bit halves
;;;; and a 64-bit result into two 32-bit values. The high half is given
;;;; the alien type (signed 33) or (unsigned 33): a width no C type has,
;;;; which the :ARG-TN and :RESULT-TN methods above turn into a TN of
;;;; primitive type WASM-I64-HIGH, and that is how CALL-OUT knows to merge
;;;; the pair into one i64 parameter (or to split an i64 result into the
;;;; two result registers).

(!def-primitive-type wasm-i64-high (signed-reg unsigned-reg signed-stack unsigned-stack)
  :type (or (signed-byte 32) (unsigned-byte 32)))

(defconstant +wasm-i64-high-bits+ 33)

(defun wasm-i64-high-tn-p (tn)
  (eq (sb-c:primitive-type-name (sb-c::tn-primitive-type tn)) 'wasm-i64-high))

(deftransform %alien-funcall ((function type &rest args) * * :node node)
  (aver (sb-c:constant-lvar-p type))
  (let* ((type (sb-c:lvar-value type))
         (env (sb-c::node-lexenv node))
         (arg-types (alien-fun-type-arg-types type))
         (result-type (alien-fun-type-result-type type)))
    (aver (= (length arg-types) (length args)))
    (flet ((wide-p (type)
             ;; not the 33-bit marker halves the transform itself makes
             (and (alien-integer-type-p type)
                  (> (sb-alien::alien-integer-type-bits type) +wasm-i64-high-bits+)))
           (high-type (type)
             (parse-alien-type (if (alien-integer-type-signed type)
                                   `(signed ,+wasm-i64-high-bits+)
                                   `(unsigned ,+wasm-i64-high-bits+))
                               env)))
      (if (or (some #'wide-p arg-types) (wide-p result-type))
          (collect ((new-args) (lambda-vars) (new-arg-types))
            (loop for type in arg-types
                  for arg = (gensym)
                  do (lambda-vars arg)
                     (cond ((wide-p type)
                            (new-args `(logand ,arg #xffffffff))
                            (new-args `(ash ,arg -32))
                            (new-arg-types (parse-alien-type '(unsigned 32) env))
                            (new-arg-types (high-type type)))
                           (t
                            (new-args arg)
                            (new-arg-types type))))
            (if (wide-p result-type)
                (let ((new-result-type
                        (let ((sb-alien::*values-type-okay* t))
                          (parse-alien-type
                           `(values (unsigned 32)
                                    ,(if (alien-integer-type-signed result-type)
                                         `(signed ,+wasm-i64-high-bits+)
                                         `(unsigned ,+wasm-i64-high-bits+)))
                           env))))
                  `(lambda (function type ,@(lambda-vars))
                     (declare (ignore type))
                     (multiple-value-bind (low high)
                         (%alien-funcall function
                                         ',(make-alien-fun-type
                                            :arg-types (new-arg-types)
                                            :result-type new-result-type)
                                         ,@(new-args))
                       (logior low (ash high 32)))))
                `(lambda (function type ,@(lambda-vars))
                   (declare (ignore type))
                   (%alien-funcall function
                                   ',(make-alien-fun-type
                                      :arg-types (new-arg-types)
                                      :result-type result-type)
                                   ,@(new-args)))))
          (sb-c::give-up-ir1-transform)))))

(defun make-call-out-tns (type)
  (let ((arg-state (make-arg-state)))
    (collect ((arg-tns))
      (dolist (arg-type (alien-fun-type-arg-types type))
        (arg-tns (invoke-alien-type-method :arg-tn arg-type arg-state)))
      (values (make-wired-tn* 'positive-fixnum any-reg-sc-number nsp-offset)
              (* (arg-state-stack-frame-size arg-state) n-word-bytes)
              (arg-tns)
              (invoke-alien-type-method :result-tn
                                        (alien-fun-type-result-type type)
                                        (make-result-state))))))

;;;; Foreign calls (doc/wasm-port/02-design.md, 2.9)
;;;;
;;;; A foreign function is an entry of the shared function table; its
;;;; "address" (the SAP of the foreign symbol, read from the linkage
;;;; table cell the runtime filled) is the table index. The
;;;; arguments were moved to their number-stack slots; CALL-OUT pushes
;;;; them on the operand stack and calls through the table with the type
;;;; the alien function type describes (a :FUNCTION-TYPE fixup the module
;;;; writer resolves). Results come back on the operand stack and go to
;;;; the result TNs.

(defun alien-tn-valtype (tn)
  (sc-case tn
    ((signed-stack unsigned-stack sap-stack signed-reg unsigned-reg sap-reg any-reg descriptor-reg)
     :i32)
    ((single-stack single-reg) :f32)
    ((double-stack double-reg) :f64)))

;;; The argument TNs are number-stack slots of the block
;;; ALLOC-NUMBER-STACK-SPACE reserved, addressed from NSP (the block's
;;; base, which MAKE-CALL-OUT-TNS hands to the argument moves).
(defun emit-alien-arg (tn)
  (sc-case tn
    ((signed-stack unsigned-stack sap-stack)
     (load-reg nsp-tn)
     (inst i32.load (tn-byte-offset tn)))
    ((signed-reg unsigned-reg sap-reg any-reg descriptor-reg)
     (load-reg tn))
    (single-stack
     (load-reg nsp-tn)
     (inst f32.load (tn-byte-offset tn)))
    (double-stack
     (load-reg nsp-tn)
     (inst f64.load (tn-byte-offset tn)))
    (single-reg (load-freg tn :single))
    (double-reg (load-freg tn :double))))

(define-vop (call-out)
  (:args (function :scs (sap-reg) :to :save)
         (args :more t))
  (:results (results :more t))
  (:save-p t)
  (:temporary (:sc control-stack :offset nfp-save-offset) nfp-save)
  (:vop-var vop)
  (:generator 0
    (let ((cur-nfp (current-nfp-tn vop))
          (params '())
          (result-tns '()))
      (when cur-nfp
        (store-stack-tn nfp-save cur-nfp))
      (do ((ref args (tn-ref-across ref)))
          ((null ref))
        (let ((tn (tn-ref-tn ref))
              (next (tn-ref-across ref)))
          (cond ((and next (wasm-i64-high-tn-p (tn-ref-tn next)))
                 ;; a 64-bit integer: the low and high halves become one i64
                 (emit-alien-arg tn)
                 (inst i64.extend_i32_u)
                 (emit-alien-arg (tn-ref-tn next))
                 (inst i64.extend_i32_u)
                 (inst i64.const 32)
                 (inst i64.shl)
                 (inst i64.or)
                 (push :i64 params)
                 (setf ref next))
                (t
                 (push (alien-tn-valtype tn) params)
                 (emit-alien-arg tn)))))
      (do ((ref results (tn-ref-across ref)))
          ((null ref))
        (push (tn-ref-tn ref) result-tns))
      (setf params (nreverse params)
            result-tns (nreverse result-tns))
      ;; An alien function the runtime does not define has the guard
      ;; undefined_alien_function in its linkage cell (a void () function,
      ;; so a typed call through it with any other signature would trap in
      ;; the host's type check): call the guard by its own type instead,
      ;; which signals UNDEFINED-ALIEN-FUNCTION-ERROR.
      (let ((undefined (gen-label)))
        (assemble (:elsewhere)
          (emit-label undefined)
          (inst i32.const (make-fixup "undefined_alien_function" :foreign))
          (inst i32.load 0)
          (inst call_indirect (make-fixup (list '() '()) :function-type))
          (inst unreachable))
        (load-reg function)
        (inst i32.const (make-fixup "undefined_alien_function" :foreign))
        (inst i32.load 0)
        (inst i32.eq)
        (inst jump-if undefined))
      (load-reg function)
      (cond ((and (= (length result-tns) 2)
                  (wasm-i64-high-tn-p (second result-tns)))
             ;; a 64-bit result: one i64, stored across the two adjacent
             ;; result registers (little-endian: low then high)
             (aver (= (tn-offset (second result-tns)) (1+ (tn-offset (first result-tns)))))
             (inst call_indirect (make-fixup (list params '(:i64)) :function-type))
             (inst f64.reinterpret_i64)
             (inst local.set +scratch-f64-local+)
             (inst global.get +thread-global+)
             (inst local.get +scratch-f64-local+)
             (inst i64.reinterpret_f64)
             (inst i64.store (register-byte-offset (tn-offset (first result-tns))))
             (setf result-tns '()))
            (t
             (inst call_indirect (make-fixup (list params (mapcar #'alien-tn-valtype result-tns))
                                             :function-type))))
      ;; the results are on the operand stack, last one on top; each is
      ;; parked in a scratch local while its register address is pushed
      (dolist (tn (reverse result-tns))
        (sc-case tn
          ((signed-reg unsigned-reg sap-reg any-reg descriptor-reg)
           (inst local.set +scratch-i32-local+)
           (inst global.get +thread-global+)
           (inst local.get +scratch-i32-local+)
           (inst i32.store (register-byte-offset (tn-offset tn))))
          (single-reg
           (inst local.set +scratch-f32-local+)
           (inst global.get +thread-global+)
           (inst local.get +scratch-f32-local+)
           (inst f32.store (float-register-byte-offset (tn-offset tn))))
          (double-reg
           (inst local.set +scratch-f64-local+)
           (inst global.get +thread-global+)
           (inst local.get +scratch-f64-local+)
           (inst f64.store (float-register-byte-offset (tn-offset tn))))))
      (when cur-nfp
        (load-stack-tn cur-nfp nfp-save)))))

(define-vop (alloc-number-stack-space)
  (:info amount)
  (:result-types system-area-pointer)
  (:results (result :scs (sap-reg any-reg)))
  (:generator 0
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount +number-stack-alignment-mask+)
                             +number-stack-alignment-mask+)))
        (store-reg nsp-tn (emit-reg-plus nsp-tn (- delta)))))
    (move result nsp-tn)))

(define-vop (dealloc-number-stack-space)
  (:info amount)
  (:policy :fast-safe)
  (:generator 0
    (unless (zerop amount)
      (let ((delta (logandc2 (+ amount +number-stack-alignment-mask+)
                             +number-stack-alignment-mask+)))
        (store-reg nsp-tn (emit-reg-plus nsp-tn delta))))))

;;; The SAP of a foreign function is the table index the runtime stored
;;; in the symbol's linkage cell (OS_LINK_RUNTIME; a C function pointer
;;; is a table index), of a foreign data symbol the address it stored
;;; there. Both fixups resolve to the cell's address.
(define-vop (foreign-symbol-sap)
  (:translate foreign-symbol-sap)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
    ;; the cell's address, for the undefined-alien guard's error message
    (inst global.get +thread-global+)
    (inst i32.const (make-fixup foreign-symbol :foreign))
    (inst i32.store +thread-foreign-cell-offset+)
    (store-reg res
      (inst i32.const (make-fixup foreign-symbol :foreign))
      (inst i32.load 0))))

(define-vop (foreign-symbol-dataref-sap)
  (:translate foreign-symbol-dataref-sap)
  (:policy :fast-safe)
  (:args)
  (:arg-types (:constant simple-string))
  (:info foreign-symbol)
  (:results (res :scs (sap-reg)))
  (:result-types system-area-pointer)
  (:generator 2
    (store-reg res
      (inst i32.const (make-fixup foreign-symbol :foreign-dataref))
      (inst i32.load 0))))

#-sb-xc-host
(defun alien-callback-accessor-form (type sap offset)
  `(deref (sap-alien (sap+ ,sap ,offset) (* ,type))))

#-sb-xc-host
(defun alien-callback-assembler-wrapper (index result-type argument-types)
  (declare (ignore index result-type argument-types))
  (error "alien callbacks are not implemented on this target yet"))
