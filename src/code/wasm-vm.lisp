;;;; This file contains the WebAssembly-specific runtime stuff.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

(defun machine-type ()
  "Return a string describing the type of the local machine."
  "WASM32")

;;; A "context" on this target is the register file the runtime saved
;;; when a trap or an interrupt entered it (doc/wasm-port/02-design.md,
;;; 2.4): the same word slots the compiled code uses. The return address
;;; register holds the descriptor of the return point of the current
;;; call, not a machine address.
(defun return-machine-address (scp)
  (context-register scp ra-offset))

;;; CONTEXT-FLOAT-REGISTER
(define-alien-routine ("os_context_float_register_addr" context-float-register-addr)
  (* unsigned) (context (* os-context-t)) (index int))

(defun context-float-register (context index format &optional integer)
  (declare (ignore integer))
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (sap-ref-single sap 0))
      (double-float
       (sap-ref-double sap 0))
      (complex-single-float
       (complex (sap-ref-single sap 0)
                (sap-ref-single sap 4)))
      (complex-double-float
       (complex (sap-ref-double sap 0)
                (sap-ref-double sap 8))))))

(defun %set-context-float-register (context index format value)
  (let ((sap (alien-sap (context-float-register-addr context index))))
    (ecase format
      (single-float
       (setf (sap-ref-single sap 0) value))
      (double-float
       (setf (sap-ref-double sap 0) value))
      (complex-single-float
       (locally
           (declare (type (complex single-float) value))
         (setf (sap-ref-single sap 0) (realpart value)
               (sap-ref-single sap 4) (imagpart value))))
      (complex-double-float
       (locally
           (declare (type (complex double-float) value))
         (setf (sap-ref-double sap 0) (realpart value)
               (sap-ref-double sap 8) (imagpart value)))))))

;;; INTERNAL-ERROR-ARGS

;;; Compiled code reports an internal error by storing one SC+OFFSET
;;; word per argument into the thread's error-argument area and calling
;;; the runtime import INTERNAL_ERROR with (kind code nargs); the runtime
;;; records the three words in front of the arguments and hands a
;;; pointer to that block to the Lisp handler through the context.
(define-alien-routine ("os_context_error_args_addr" context-error-args-addr)
  (* unsigned) (context (* os-context-t)))

(defun internal-error-args (context)
  (declare (type (alien (* os-context-t)) context))
  (let* ((sap (alien-sap (context-error-args-addr context)))
         (kind (sap-ref-32 sap 0))
         (code (sap-ref-32 sap 4))
         (nargs (sap-ref-32 sap 8)))
    ;; the third value is the trap number, which INTERNAL-ERROR compares
    ;; with CERROR-TRAP
    (if (= kind invalid-arg-count-trap)
        (values #.(error-number-or-lose 'invalid-arg-count-error)
                '(#.arg-count-sc)
                kind)
        (values code
                (loop for i below nargs
                      collect (sap-ref-32 sap (+ 12 (* i 4))))
                kind))))

;;; CONTEXT-CALL-FUNCTION

;;; Undo the effects of XEP-ALLOCATE-FRAME and point PC to FUNCTION.
;;; Redirecting a trapped function needs the runtime's help on this
;;; target (there is no PC to rewrite); it belongs to the runtime port.
(defun context-call-function (context function &optional arg-count)
  (declare (ignore context function arg-count))
  (style-warn "Unimplemented."))

;;;; Code loaded at run time
;;;;
;;;; A fasl carries the Wasm functions of each code component after the
;;;; code object (FOP-WASM-CODE). Instantiating them as a module of their
;;;; own needs the host's instantiate import, which the runtime provides
;;;; from Sprint 6 on.
;;;; Loading code at run time (doc/wasm-port/02-design.md, 2.2).
;;;;
;;;; A code object's functions arrive as the blob the compiler produced
;;;; (SERIALIZE-WASM-CODE): from a fasl (FOP-WASM-CODE) or from an
;;;; in-memory compile (MAKE-CORE-COMPONENT). They become a module of
;;;; their own, built the way genesis builds the core module: the
;;;; patches resolved (function references within the module, assembly
;;;; routines imported from the shared table by index, foreign symbols
;;;; through their linkage cells, layout ids), the functions installed in
;;;; the shared table at a fresh range, and the host asked to instantiate
;;;; the module against the runtime's memory, table and register area.

;;; ("NAME" . table-index) of the core module's assembly routines, and the
;;; first free table index; both set by genesis (BUILD-WASM-CORE-MODULE).
(defvar *wasm-routine-table*)
(defvar *wasm-table-next*)

(defun wasm-routine-table-index (name)
  (or (cdr (assoc name *wasm-routine-table* :test #'string=))
      (error "assembly routine ~A is not in the core module" name)))

(defun wasm-layout-id-of (qualified-name)
  ;; "PACKAGE::NAME" of the classoid (func-asm.lisp, LOADER-FIXUPS)
  (let* ((colons (search "::" qualified-name))
         (symbol (find-symbol (subseq qualified-name (+ colons 2))
                              (subseq qualified-name 0 colons))))
    (sb-kernel::ensure-layout-id
     (find-layout (or symbol (error "no such layout: ~A" qualified-name))))))

(define-alien-routine ("wasm_instantiate_module" %wasm-instantiate-module) int
  (bytes system-area-pointer) (length unsigned-int) (table-base unsigned-int))

(defvar *wasm-loaded-modules* nil
  "The modules instantiated at run time, as (table-base . bytes), newest
first. A saved core keeps them; the runtime instantiates them again, in
order, when the core starts (wasm_load_core_module).")

(defun wasm-install-code (code octets)
  "Build a module from OCTETS, the compiler's blob for the functions of
the code object CODE, instantiate it, and store each entry's table index
in its simple-fun's self slot."
  (multiple-value-bind (functions entries) (sb-wasm-asm::parse-wasm-code octets)
    (let* ((module (sb-wasm-asm::make-lisp-module))
           (routine-imports '()))
      ;; the assembly routines the code calls directly: imported from the
      ;; shared table by index (import module "table", name the index)
      (dolist (f functions)
        (loop for (nil kind operand) in (sb-wasm-asm::wasm-function-patches f)
              when (and (eq kind :assembly-routine)
                        (not (assoc operand routine-imports :test #'string=)))
                do (push (cons operand
                               (sb-wasm-asm::wasm-import-function
                                module "table"
                                (princ-to-string (wasm-routine-table-index operand))
                                sb-wasm-asm::+lisp-function-params+
                                sb-wasm-asm::+lisp-function-results+))
                         routine-imports)))
      (let* ((base (sb-wasm-asm::wasm-import-count module :func))
             (n (length functions))
             (table-base *wasm-table-next*)
             (indices '()))
        (setf *wasm-table-next* (+ table-base n))
        (loop for f in functions
              for i from base
              do (setf (sb-wasm-asm::wasm-function-index f) i))
        (flet ((table-slot (module-index) (+ table-base (- module-index base))))
          (dolist (f functions)
            (let ((body (sb-wasm-asm::wasm-function-body f)))
              (loop for (offset kind operand) in (sb-wasm-asm::wasm-function-patches f)
                    do (sb-wasm-asm::patch-fixed-leb128
                        body offset
                        (ecase kind
                          (:function (+ base operand))
                          (:assembly-routine (cdr (assoc operand routine-imports :test #'string=)))
                          (:type (sb-wasm-asm::wasm-type-index module (first operand) (second operand)))
                          (:assembly-routine-entry (wasm-routine-table-index operand))
                          (:foreign
                           (alien-linkage-index-to-addr
                            (sb-impl::ensure-alien-linkage-index operand nil) nil))
                          (:foreign-dataref
                           (alien-linkage-index-to-addr
                            (sb-impl::ensure-alien-linkage-index operand t) t))
                          (:coverage (error "code coverage is not supported on this target yet"))
                          (:layout-id (wasm-layout-id-of operand)))
                        (sb-wasm-asm::patch-kind-signed-p kind)))
              (push (sb-wasm-asm::wasm-add-function
                     module sb-wasm-asm::+lisp-function-params+ sb-wasm-asm::+lisp-function-results+
                     (sb-wasm-asm::wasm-function-locals f) body
                     :name (sb-wasm-asm::wasm-function-name f))
                    indices)))
          (sb-wasm-asm::wasm-add-elements
           module 0 (sb-wasm-asm::i32-const-expression table-base) (nreverse indices))
          ;; the table range, for the host: two little-endian u32
          (let ((range (make-array 8 :element-type '(unsigned-byte 8))))
            (loop for (value start) in (list (list table-base 0) (list n 4))
                  do (dotimes (i 4)
                       (setf (aref range (+ start i)) (ldb (byte 8 (* 8 i)) value))))
            (sb-wasm-asm::wasm-add-custom-section module "sbcl.core.table" range))
          (let ((bytes (coerce (sb-wasm-asm::wasm-module-octets module)
                               '(simple-array (unsigned-byte 8) (*)))))
            (with-pinned-objects (bytes)
              (when (zerop (%wasm-instantiate-module (vector-sap bytes) (length bytes) table-base))
                (error "the host could not instantiate the module of ~S" code)))
            ;; kept for SAVE-LISP-AND-DIE: a saved core instantiates them again
            (push (cons table-base bytes) *wasm-loaded-modules*))
          ;; the simple-funs' self slots: table indices. ENTRIES is in
          ;; IR2-COMPONENT-ENTRIES order, numbered from the last simple-fun
          ;; of the code object down (FOP-FUN-ENTRY, genesis).
          (with-pinned-objects (code)
            (loop for fun-index downfrom (1- (length entries))
                  for local in entries
                  do (let ((fun (sb-kernel:%code-entry-point code fun-index)))
                       (setf (sap-ref-word (int-sap (get-lisp-obj-address fun))
                                           (- (ash simple-fun-self-slot word-shift) fun-pointer-lowtag))
                             (table-slot (sb-wasm-asm::wasm-function-index (nth local functions)))))))))
      code)))

;;; A funcallable instance is entered through its function slot, by the
;;; compiled call sequence (EMIT-FUNCTION-OBJECT-ENTRY) and by the
;;; runtime's call_into_lisp alike; there is no trampoline to write.
(defun write-funinstance-prologue (object)
  (declare (ignore object))
  nil)

;;; Without dynamic loading (#-os-provides-dlopen) there is no dlsym; the
;;; runtime's linkage lookup (os_dlsym_default, over the table generated
;;; from the core's required symbols) answers instead: a function's
;;; table index or a data symbol's address, or 0 when unknown.
(defun sb-sys:find-dynamic-foreign-symbol-address (symbol)
  (let ((addr (alien-funcall (extern-alien "os_dlsym_default"
                                           (function unsigned-int c-string))
                             symbol)))
    (if (zerop addr) nil addr)))
