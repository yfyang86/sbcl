;;;; The function assembler: control-flow lowering for the WebAssembly
;;;; backend.
;;;;
;;;; Codegen produces a linear byte stream with labels and the branch
;;;; pseudo-instructions of insts.lisp. Wasm has structured control flow
;;;; only, so each function is rewritten here into the "dispatch loop"
;;;; form of doc/wasm-port/02-design.md, 2.5:
;;;;
;;;;   loop $L
;;;;     block $B(n-1) ... block $B1 block $B0
;;;;       local.get $pc  br_table $B0 $B1 ... $B(n-1)
;;;;     end  <arm 0>  end  <arm 1> ... end  <arm n-1>
;;;;   end
;;;;   unreachable
;;;;
;;;; Every branch target label starts an arm; falling off the end of an
;;;; arm continues into the next one, which is the original linear order,
;;;; so fall-through costs nothing. A taken branch sets $pc and branches
;;;; to the loop head. The stackifier (Phase 3) replaces this encoding
;;;; for reducible control flow.
;;;;
;;;; A component becomes one Wasm function per environment (lambda with
;;;; a frame): codegen records the environment of every block, the blocks
;;;; of one environment form the chunks of its function, and the edges
;;;; between environments (tail local calls, which IR2 lowers to a jump
;;;; or a fall-through into the callee's first block) become RETURN_CALL.
;;;; Local calls (CALL-LABEL) become CALL. Functions with a non-local
;;;; entry get an exception handler around the dispatcher (2.6).
;;;;
;;;; The operand stack must be empty at every label and at every
;;;; pseudo-instruction except for the value a JUMP-IF or JUMP-TABLE
;;;; consumes; the VOPs guarantee this.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-WASM-ASM")

;;;; Fixed indices of every module the backend emits (see MAKE-LISP-MODULE
;;;; below); the SB-VM ones are shared with macros.lisp, which is compiled
;;;; after this file.

;;; the imports: memory, table, the globals THREAD and TABLE_BASE, the tag
(defconstant +global-thread+ 0)
(defconstant +global-table-base+ 1)
;;; the module's own mutable global through which a call from another
;;; function of the same component enters at an arm other than the
;;; function's start: 0 (the default) means the start, else arm + 1
(defconstant +global-entry-arm+ 2)
;;; the runtime entry points (+IMPORT-...+ in macros.lisp), which precede
;;; the assembly routine imports in the function index space
(defconstant sb-vm::+n-runtime-imports+ 4)
;;; the type index of the Lisp function signature
(defconstant sb-vm::+lisp-function-type-index+ 0)
;;; the tag index of the unwind tag
(defconstant sb-vm::+tag-lisp-unwind+ 0)
;;; thread-area word holding the block an unwind is targeting
(defconstant sb-vm::+thread-unwind-target-offset+ 448)

;;; Every Lisp function (no parameters) starts with one local per
;;; register slot, the register cache (+REGISTER-LOCALS-BASE+, insts.lisp;
;;; EMIT-RELOAD and EMIT-FLUSH below move them from and to the register
;;; area), then three scratch locals a VOP may use to reorder operands,
;;; since Wasm has no swap: a value already on the operand stack can be
;;; parked while the address it is stored to is pushed (see CALL-OUT in
;;; c-call.lisp).
(defconstant sb-vm::+n-register-locals+ 32)
(defconstant sb-vm::+scratch-i32-local+ 32)
(defconstant sb-vm::+scratch-f32-local+ 33)
(defconstant sb-vm::+scratch-f64-local+ 34)
(defconstant sb-vm::+n-scratch-locals+ 3)

;;; The stackifier (stackify.lisp, compiled after this file) is the
;;; lowering of choice; the dispatch loop below is its fallback.
(defvar sb-vm::*wasm-stackify* t
  "Whether functions are lowered with structured control flow (the
stackifier) or the dispatch loop.")
(defvar sb-vm::*wasm-stackify-fallback-hook* nil
  "Called with the function when its control flow is irreducible and
the dispatch loop is used instead.")

;;; The uniform signature of a Lisp entry point: NARGS and A0..A3 are the
;;; parameters (their locals are the first five, REGISTER-LOCAL in
;;; insts.lisp), the result is the values flag (call.lisp).
(defconstant-eqx +lisp-function-params+ '(:i32 :i32 :i32 :i32 :i32) #'equal)
(defconstant-eqx +lisp-function-results+ '(:i32) #'equal)
;;; the registers that are parameters: NARGS, A0..A3
(defconstant +lisp-param-register-mask+ #x3C01)

;;;; Byte ranges and arms

(defun range-contains-p (range position)
  (and (<= (car range) position) (< position (cdr range))))

(defun note-targets (note)
  "The labels a control note may branch to within its function."
  (ecase (control-note-kind note)
    ((:jump :jump-if :nlx-entry :label-index) (list (control-note-labels note)))
    (:jump-table (append (control-note-labels note) (list (control-note-data note))))
    ((:func-begin :func-end :call-label :tail-call-label :terminator :flush :reload) '())))

;;; An arm is a byte range of the segment; arms are numbered in the
;;; order they are emitted, which is range order then position order.
(defstruct (arm (:copier nil))
  (index 0 :type index)
  (start 0 :type index)
  (end 0 :type index)
  ;; true for the last arm of a code chunk (see CHUNK-EXIT)
  (chunk-end-p nil))

(defun compute-arms (ranges target-positions)
  "Split RANGES at every target position within them; return the arms."
  (let ((arms '()) (index 0))
    (dolist (range ranges)
      (let ((boundaries (sort (remove-duplicates
                               (cons (car range)
                                     (remove-if-not (lambda (p) (and (< (car range) p)
                                                                     (<= p (cdr range))))
                                                    target-positions)))
                              #'<)))
        (loop for (start next) on boundaries
              do (push (make-arm :index index :start start :end (or next (cdr range))
                                 :chunk-end-p (null next))
                       arms)
                 (incf index))))
    (nreverse arms)))

(defun arm-at (arms position)
  "The arm that starts at POSITION (a branch target): the one with code
there when two start there. A target at the end of a range gets an empty
arm (COMPUTE-ARMS) so that a jump to it can leave for the function
continuing there; when a range of the same function starts at that
position, its first arm is the target and the empty arm is dead."
  (or (find-if (lambda (arm) (and (= (arm-start arm) position)
                                  (< (arm-start arm) (arm-end arm))))
               arms)
      (find position arms :key #'arm-start)
      (error "no arm starts at position ~D" position)))

;;;; Functions of a component

(defstruct (wasm-function (:copier nil))
  ;; the SB-C environment, or the routine name for an assembly routine
  (env nil)
  ;; position in the module's list of defined functions
  (index 0 :type index)
  ;; the entry-info when the environment is an external entry point
  (entry nil)
  ;; byte position of the first block
  (start 0 :type index)
  ;; code chunks ((start . end) ...) in emission order
  (chunks '())
  (body nil)
  (locals '())
  ;; (body-offset params results) of every :function-type fixup, which
  ;; the module writer resolves to a type index
  (type-patches '())
  ;; (body-offset kind operand) for every five-byte immediate that a
  ;; loader has to patch when the function is installed in a module other
  ;; than the one it was lowered for (see SERIALIZE-WASM-CODE):
  ;;   :function        operand: index of a function of the same component
  ;;   :assembly-routine  operand: the routine's name (a string)
  ;;   :type            operand: (params results)
  ;;   :assembly-routine-entry, :foreign, :foreign-dataref: a name (string)
  ;;   :coverage        operand: a coverage index
  (patches '())
  ;; a name given explicitly (functions read back from a blob)
  (name-slot nil)
  ;; set by ASSIGN-ARMS before emission: the code ranges (chunks plus the
  ;; elsewhere chunks the function reaches), the control notes in them,
  ;; the arms, and the arm index of the start
  (ranges '())
  (notes '())
  (arms '())
  (start-arm 0 :type index)
  ;; true when another function enters this one at an arm other than
  ;; its start, through +GLOBAL-ENTRY-ARM+
  (entry-arm-p nil)
  ;; the registers the function's code touches (a bit per register
  ;; slot): the locals its prologue reads from the register area and its
  ;; flush points write back (LOWER-FUNCTIONS, from the REG.GET/REG.SET
  ;; records of the segment)
  (reg-mask 0 :type (unsigned-byte 32)))

(defun wasm-function-name (function)
  (let ((entry (wasm-function-entry function))
        (env (wasm-function-env function)))
    (cond ((wasm-function-name-slot function))
          (entry (princ-to-string (sb-c::entry-info-name entry)))
          ((symbolp env) (string-downcase env))
          (t (format nil "lambda~D" (wasm-function-index function))))))

;;;; Emission

(defvar *open* '()
  "The open control constructs at the current point, innermost first.
Each element is a tag; :loop marks the dispatch loop.")

(defun depth-of (tag)
  (or (position tag *open*)
      (error "control construct ~S is not open" tag)))

;;; Emission context of one function.
(defstruct (fctx (:copier nil))
  bytes        ; the segment's bytes
  arms
  functions    ; all functions of the component, by index
  pc-local
  ;; function index of the first defined function in the module
  function-base
  ;; position -> function index for :assembly-routine fixups
  asm-patches
  ;; position -> (params results) for :function-type fixups
  type-fixups
  ;; position -> (flavor . name) for every other fixup the loader patches
  fixups
  ;; the labels of the compiler's blocks: a branch to one is a branch
  ;; between blocks, and backward it is a loop's safe point
  (block-labels '())
  ;; function -> the arms other than its start entered from other
  ;; functions of the component (COMPONENT-ENTRY-ARMS, stackify.lisp)
  (entry-arms '())
  ;; the function being lowered
  function)

(defun function-starting-at (ctx position)
  (find position (fctx-functions ctx) :key #'wasm-function-start))

(defun function-continuing-at (ctx position)
  "The function control falls into at POSITION, the end of a chunk of
the current function: a function starting there other than the current
one, preferring one that has code there (an environment whose first
block is empty starts at the same position as the next one)."
  (let ((current (fctx-function ctx))
        (candidates (remove-if-not
                     (lambda (f) (find position (wasm-function-ranges f) :key #'car))
                     (fctx-functions ctx))))
    (flet ((code-at-p (function)
             (some (lambda (chunk) (< (car chunk) (cdr chunk)))
                   (wasm-function-chunks function))))
      (or (find-if (lambda (f) (and (not (eq f current)) (code-at-p f))) candidates)
          (find-if (lambda (f) (not (eq f current))) candidates)))))

(defun function-containing (ctx position)
  "The function whose code ranges contain POSITION (the position of a
label another function branches to)."
  (or (find-if (lambda (f)
                 (some (lambda (r) (range-contains-p r position)) (wasm-function-ranges f)))
               (fctx-functions ctx))
      ;; an empty function's range is (p . p)
      (find-if (lambda (f) (find position (wasm-function-ranges f) :key #'car))
               (fctx-functions ctx))
      (error "no function contains position ~D" position)))

(defun emit-cross-ref (buffer ctx position opcode)
  "A call (OPCODE #x10) or return_call (#x12) into the function
containing POSITION, entering at the arm that starts there: when that is
not the callee's start arm, the arm is passed through +GLOBAL-ENTRY-ARM+."
  (let* ((callee (function-containing ctx position))
         (arm (arm-at (wasm-function-arms callee) position)))
    (unless (= (arm-index arm) (wasm-function-start-arm callee))
      (setf (wasm-function-entry-arm-p callee) t)
      (buffer-byte buffer #x41) (buffer-sleb128 buffer (1+ (arm-index arm)))   ; i32.const
      (buffer-byte buffer #x24) (buffer-uleb128 buffer +global-entry-arm+))    ; global.set
    ;; the callee reads the register area (its prologue) and writes it
    ;; back before returning
    (emit-flush buffer ctx)
    (emit-lisp-args buffer)
    (buffer-byte buffer opcode)
    (emit-function-ref buffer ctx callee)
    (when (= opcode #x10)
      (emit-reload buffer ctx))))

(defun emit-function-ref (buffer ctx function)
  "The module index of FUNCTION (of the same component) as a fixed
five-byte immediate, recorded as a :FUNCTION patch of the current
function so that a loader can renumber it."
  (push (list (fill-pointer buffer) :function (wasm-function-index function))
        (wasm-function-patches (fctx-function ctx)))
  (emit-fixed-uleb128-32 buffer (+ (fctx-function-base ctx) (wasm-function-index function))))

(defun emit-set-pc-and-loop (buffer pc-local arm-index)
  (buffer-byte buffer #x41) (buffer-sleb128 buffer arm-index) ; i32.const arm
  (buffer-byte buffer #x21) (buffer-uleb128 buffer pc-local)  ; local.set $pc
  (buffer-byte buffer #x0C) (buffer-uleb128 buffer (depth-of :loop))) ; br $L

(defun emit-fixed-uleb128-32 (buffer value)
  "A five-byte LEB128, the size the assembler reserved for a fixup."
  (dotimes (i 4)
    (buffer-byte buffer (logior (logand value #x7F) #x80))
    (setf value (ash value -7)))
  (buffer-byte buffer (logand value #x0F)))

;;; The safe point of a loop: a jump back to an arm at or before the
;;; current one polls the thread's interrupt-pending word, as every entry
;;; does (EMIT-SAFE-POINT, call.lisp), so that a loop without calls
;;; still sees the host's interrupt, the timer and a pending collection.
;;; The word is zero unless something is pending: a load and a branch.
;;; (macros.lisp, compiled after this file: +THREAD-INTERRUPT-PENDING-OFFSET+
;;; and +IMPORT-PENDING-INTERRUPT+ are these)
(defconstant +poll-word-offset+ 456)
(defconstant +poll-import+ 3)
(defun emit-back-edge-poll (buffer ctx)
  (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+)  ; global.get thread
  (buffer-byte buffer #x28) (buffer-byte buffer 2)                    ; i32.load align=2
  (buffer-uleb128 buffer +poll-word-offset+)
  (buffer-byte buffer #x04) (buffer-byte buffer +empty-block-type+)   ; if
  (emit-flush buffer ctx)
  (buffer-byte buffer #x10) (buffer-uleb128 buffer +poll-import+)     ; call pending_interrupt
  (emit-reload buffer ctx)
  (buffer-byte buffer #x0B))                                          ; end

;;; The register cache (insts.lisp, REG.GET and REG.SET): the registers
;;; of the function's REG-MASK, and of MASK when given, written from
;;; their locals to the register area (EMIT-FLUSH) or read from it
;;; (EMIT-RELOAD). The area is the truth at every function entry, at a
;;; call, a return, a throw and a runtime entry point.
;;;
;;; The parameter registers (NARGS and A0..A3, the parameters of every
;;; Lisp function) are in every Lisp function's REG-MASK whether a
;;; REG.GET or REG.SET recorded them or not (LOWER-FUNCTIONS): a value
;;; can sit in one of them without the function touching it, an argument
;;; returned as it came, a local callee's result returned in turn, and
;;; the function's local and the area each hold the truth at different
;;; times (the local at entry, the area after a callee's return); so
;;; they are flushed and reloaded like any register the function uses.
(defun emit-flush (buffer ctx &optional mask)
  (let ((registers (logand (wasm-function-reg-mask (fctx-function ctx)) (or mask -1))))
    (dotimes (i sb-vm::+n-register-locals+)
      (when (logbitp i registers)
        (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+)   ; global.get thread
        (buffer-byte buffer #x20) (buffer-uleb128 buffer (register-local i)) ; local.get
        (buffer-byte buffer #x36) (buffer-byte buffer 2)                    ; i32.store align=2
        (buffer-uleb128 buffer (* i sb-vm::n-word-bytes))))))

(defun emit-reload (buffer ctx &optional mask)
  (let ((registers (logand (wasm-function-reg-mask (fctx-function ctx)) (or mask -1))))
    (dotimes (i sb-vm::+n-register-locals+)
      (when (logbitp i registers)
        (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+)   ; global.get thread
        (buffer-byte buffer #x28) (buffer-byte buffer 2)                    ; i32.load align=2
        (buffer-uleb128 buffer (* i sb-vm::n-word-bytes))
        (buffer-byte buffer #x21) (buffer-uleb128 buffer (register-local i)))))) ; local.set

;;; The registers a function's prologue reads from the area: all it
;;; uses but the parameters, which arrive as such.
(defun prologue-reload-mask (params)
  (if (equal params +lisp-function-params+)
      (lognot +lisp-param-register-mask+)
      -1))

;;; The parameters of a Lisp call, from this function's locals.
(defun emit-lisp-args (buffer)
  (dotimes (i (length +lisp-function-params+))
    (buffer-byte buffer #x20) (buffer-uleb128 buffer (+ +register-locals-base+ i)))) ; local.get

(defun emit-note-lowering (buffer note ctx)
  (let ((arms (fctx-arms ctx))
        (pc-local (fctx-pc-local ctx)))
    (flet ((target-arm (label)
             (arm-index (arm-at arms (sb-assem:label-position label))))
           (local-target-p (label)
             (find (sb-assem:label-position label) arms :key #'arm-start))
           ;; a branch between the compiler's blocks (the target is a
           ;; block's label; a branch inside a VOP targets a label of
           ;; its own) going back: a loop's safe point
           (backward-p (label)
             (and (or (eq (control-note-data note) :poll)
                      (member label (fctx-block-labels ctx) :test #'eq))
                  (<= (sb-assem:label-position label) (control-note-posn note)))))
      (ecase (control-note-kind note)
        (:jump
         (let ((label (control-note-labels note)))
           (cond ((local-target-p label)
                  (when (backward-p label) (emit-back-edge-poll buffer ctx))
                  (emit-set-pc-and-loop buffer pc-local (target-arm label)))
                 (t
                  ;; a tail local call into another function
                  (emit-cross-ref buffer ctx (sb-assem:label-position label) #x12)))))
        (:jump-if
         ;; condition is on the operand stack
         (let ((label (control-note-labels note)))
           (buffer-byte buffer #x04) (buffer-byte buffer +empty-block-type+) ; if
           (let ((*open* (cons :if *open*)))
             (cond ((local-target-p label)
                    (when (backward-p label) (emit-back-edge-poll buffer ctx))
                    (emit-set-pc-and-loop buffer pc-local (target-arm label)))
                   (t
                    (emit-cross-ref buffer ctx (sb-assem:label-position label) #x12))))
           (buffer-byte buffer #x0B)))                                    ; end
        (:jump-table
         ;; index is on the operand stack: one block per case plus one for
         ;; the default; br_table picks the block, whose code sets $pc. A
         ;; block starts a fresh operand stack, so the index is parked in
         ;; the scratch local first.
         (let* ((labels (control-note-labels note))
                (default (control-note-data note))
                (n (length labels))
                (tags (loop for i from 0 to n collect (list :case i))))
           (buffer-byte buffer #x21) (buffer-uleb128 buffer (1+ pc-local)) ; local.set $tmp
           ;; open D (outermost) then C(n-1) ... C0 (innermost)
           (let ((*open* *open*))
             (dolist (tag (reverse tags))
               (buffer-byte buffer #x02) (buffer-byte buffer +empty-block-type+)
               (push tag *open*))
             (buffer-byte buffer #x20) (buffer-uleb128 buffer (1+ pc-local)) ; local.get $tmp
             (buffer-byte buffer #x0E)                                     ; br_table
             (buffer-uleb128 buffer n)
             (dotimes (i n) (buffer-uleb128 buffer i))
             (buffer-uleb128 buffer n)
             ;; close C0 .. C(n-1) then D, each followed by its dispatch
             (loop for i from 0 to n
                   for label in (append labels (list default))
                   do (buffer-byte buffer #x0B)                             ; end
                      (pop *open*)
                      (emit-set-pc-and-loop buffer pc-local (target-arm label))))))
        (:call-label
         (emit-cross-ref buffer ctx (sb-assem:label-position (control-note-labels note)) #x10))
        (:tail-call-label
         (emit-cross-ref buffer ctx (sb-assem:label-position (control-note-labels note)) #x12))
        (:label-index
         (buffer-byte buffer #x41)                                        ; i32.const
         (buffer-sleb128 buffer (target-arm (control-note-labels note))))
        (:flush (emit-flush buffer ctx (control-note-data note)))
        (:reload (emit-reload buffer ctx (control-note-data note)))
        ((:func-begin :func-end :nlx-entry :terminator)
         nil)))))

;;; The exception handler of a function with non-local entries: the
;;; unwind routine stored the target block in the thread and threw
;;; LISP_UNWIND. A block of this frame (its CFP slot equals CFP) is
;;; entered through the dispatcher at the arm index the block holds;
;;; any other block belongs to a caller, so the exception is rethrown.
(defun emit-nlx-handler (buffer pc-local ctx)
  (flet ((load-target ()
           (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+) ; global.get thread
           (buffer-byte buffer #x28) (buffer-byte buffer 2)                ; i32.load align=2
           (buffer-uleb128 buffer sb-vm::+thread-unwind-target-offset+))
         (placeholder ()
           ;; a five-byte immediate a loader patches
           (loop repeat 4 do (buffer-byte buffer #x80))
           (buffer-byte buffer #x00)))
    (load-target)
    (buffer-byte buffer #x28) (buffer-byte buffer 2)
    (buffer-uleb128 buffer (* sb-vm::unwind-block-cfp-slot sb-vm::n-word-bytes))
    (buffer-byte buffer #x20) (buffer-uleb128 buffer (+ pc-local 2))      ; local.get $fp
    (buffer-byte buffer #x47)                                             ; i32.ne
    (buffer-byte buffer #x04) (buffer-byte buffer +empty-block-type+)     ; if
    (buffer-byte buffer #x08) (buffer-uleb128 buffer sb-vm::+tag-lisp-unwind+) ; throw
    (buffer-byte buffer #x0B)                                             ; end
    ;; the C shadow stack pointer the block saved (STORE-C-STACK-POINTER,
    ;; nlx.lisp): restored through the runtime's c_stack_restore, called
    ;; by the index in its linkage cell
    (let ((function (fctx-function ctx)))
      (load-target)
      (buffer-byte buffer #x28) (buffer-byte buffer 2)
      (buffer-uleb128 buffer (* sb-vm::unwind-block-c-sp-slot sb-vm::n-word-bytes))
      (buffer-byte buffer #x41)                                           ; i32.const cell
      (push (list (fill-pointer buffer) :foreign "c_stack_restore")
            (wasm-function-patches function))
      (placeholder)
      (buffer-byte buffer #x28) (buffer-byte buffer 2) (buffer-uleb128 buffer 0) ; i32.load
      (buffer-byte buffer #x11)                                           ; call_indirect
      (push (list (fill-pointer buffer) '(:i32) '())
            (wasm-function-type-patches function))
      (push (list (fill-pointer buffer) :type (list '(:i32) '()))
            (wasm-function-patches function))
      (placeholder)
      (buffer-byte buffer 0))                                             ; table 0
    (load-target)
    (buffer-byte buffer #x28) (buffer-byte buffer 2)
    (buffer-uleb128 buffer (* sb-vm::unwind-block-entry-pc-slot sb-vm::n-word-bytes))
    ;; the slot holds the entry index as a fixnum (STORE-ENTRY-INDEX, nlx.lisp)
    (buffer-byte buffer #x41) (buffer-sleb128 buffer sb-vm:n-fixnum-tag-bits) ; i32.const
    (buffer-byte buffer #x76)                                             ; i32.shr_u
    (buffer-byte buffer #x21) (buffer-uleb128 buffer pc-local)            ; local.set $pc
    ;; the unwind routine set the block's frame and code in the area
    (emit-reload buffer ctx)
    (buffer-byte buffer #x0C) (buffer-uleb128 buffer (depth-of :loop))))  ; br $L

(defun chunk-exit (buffer arm ctx)
  "Code after the last arm of a chunk: the next block in emission order
belongs to another function. Either it is that function's first block
(a tail local call that IR2 lowered to a fall-through) or the arm ended
with a return or a jump and this is not reached."
  (let ((next (function-continuing-at ctx (arm-end arm))))
    (cond (next
           (emit-cross-ref buffer ctx (arm-end arm) #x12))
          (t
           (buffer-byte buffer #x00)))))                                  ; unreachable

(defun emit-arm-bytes (buffer ctx from to)
  "Copy segment bytes [FROM, TO), patching assembly-routine fixups and
recording every fixup (a five-byte immediate) by its offset in the body."
  (let ((bytes (fctx-bytes ctx))
        (position from))
    (loop while (< position to)
          do (let ((patch (cdr (assoc position (fctx-asm-patches ctx))))
                   (type (cdr (assoc position (fctx-type-fixups ctx))))
                   (fixup (cdr (assoc position (fctx-fixups ctx))))
                   (function (fctx-function ctx)))
               (cond (patch
                      (push (list (fill-pointer buffer) :assembly-routine (string (cdr patch)))
                            (wasm-function-patches function))
                      (emit-fixed-uleb128-32 buffer (car patch))
                      (incf position 5))
                     (type
                      (push (list (fill-pointer buffer) (first type) (second type))
                            (wasm-function-type-patches function))
                      (push (list (fill-pointer buffer) :type type)
                            (wasm-function-patches function))
                      (loop repeat 5 do (buffer-byte buffer (aref bytes position)) (incf position)))
                     (fixup
                      (push (list (fill-pointer buffer) (car fixup) (cdr fixup))
                            (wasm-function-patches function))
                      (loop repeat 5 do (buffer-byte buffer (aref bytes position)) (incf position)))
                     (t
                      (buffer-byte buffer (aref bytes position))
                      (incf position)))))))

(defun loader-fixups (segment)
  "Position -> (flavor . operand) for the fixups a loader patches in the
function bodies, other than assembly-routine calls and function types:
the operand is a name string, or a coverage index."
  (loop for note in (sb-assem::segment-fixup-notes segment)
        for fixup = (sb-c::fixup-note-fixup note)
        for flavor = (sb-c::fixup-flavor fixup)
        when (member flavor '(:assembly-routine-entry :foreign :foreign-dataref
                              :code-coverage-index :layout-id))
        collect (cons (sb-c::fixup-note-position note)
                      (cons (if (eq flavor :code-coverage-index) :coverage flavor)
                            (let ((name (sb-c::fixup-name fixup)))
                              (case flavor
                                (:code-coverage-index name)
                                ;; the layout's classoid name, as PACKAGE::NAME
                                (:layout-id
                                 ;; the host's SYMBOL-PACKAGE and PACKAGE-NAME: this
                                 ;; file is compiled for the cross-compiler, whose
                                 ;; CL package hides them
                                 (let* ((symbol (sb-kernel::layout-classoid-name name))
                                        (package (funcall (intern "SYMBOL-PACKAGE" "COMMON-LISP")
                                                          symbol)))
                                   (concatenate 'string
                                                (funcall (intern "PACKAGE-NAME" "COMMON-LISP")
                                                         package)
                                                "::" (symbol-name symbol))))
                                (t (string name))))))))

(defun function-type-fixups (segment)
  "Position -> (params results) for every :function-type fixup."
  (loop for note in (sb-assem::segment-fixup-notes segment)
        for fixup = (sb-c::fixup-note-fixup note)
        when (eq (sb-c::fixup-flavor fixup) :function-type)
        collect (cons (sb-c::fixup-note-position note) (sb-c::fixup-name fixup))))

(defun patch-type-indices (module function)
  "Resolve the function's :FUNCTION-TYPE fixups against MODULE's types."
  (let ((body (wasm-function-body function)))
    (loop for (offset params results) in (wasm-function-type-patches function)
          do (let ((index (wasm-type-index module params results)))
               (dotimes (i 4)
                 (setf (aref body (+ offset i)) (logior (logand index #x7F) #x80))
                 (setf index (ash index -7)))
               (setf (aref body (+ offset 4)) (logand index #x0F))))))

(defun assign-arms (function ranges notes component-notes)
  "Record FUNCTION's code RANGES and the NOTES in them, and split the
ranges into arms at every label any note of the component (not only its
own) branches to, plus the function's start."
  (let* ((targets (loop for note in component-notes
                        append (mapcar #'sb-assem:label-position (note-targets note))))
         (local-targets (remove-if-not
                         (lambda (p) (some (lambda (r) (or (range-contains-p r p) (= p (cdr r))))
                                           ranges))
                         targets))
         (arms (compute-arms ranges (cons (wasm-function-start function) local-targets))))
    (setf (wasm-function-ranges function) ranges
          (wasm-function-notes function) notes
          (wasm-function-arms function) arms
          (wasm-function-start-arm function)
          (arm-index (arm-at arms (wasm-function-start function))))
    function))

(defun lower-function-body (ctx &key (params +lisp-function-params+) (locals '()))
  "Lower the function of CTX (its ranges, notes and arms assigned by
ASSIGN-ARMS) into a Wasm function body. Returns the body octets (ending
with END) and the local declarations ((count . type) ...)."
  (let* ((function (fctx-function ctx))
         (notes (wasm-function-notes function))
         (arms (wasm-function-arms function))
         (start-arm (wasm-function-start-arm function))
         (n (length arms))
         ;; the three scratch locals VOPs may use (+SCRATCH-I32-LOCAL+ and
         ;; friends in macros.lisp), then $pc
         ;; the register locals (the parameters are the first of them),
         ;; the scratch locals, $pc, the jump-table scratch local and
         ;; (with non-local entries) $fp precede the caller's locals
         (pc-local (+ sb-vm::+n-register-locals+ sb-vm::+n-scratch-locals+))
         (nlx-p (some (lambda (note) (eq (control-note-kind note) :nlx-entry)) notes))
         (all-locals (list* (cons (- sb-vm::+n-register-locals+ (length params)) :i32)
                            '(1 . :i32) '(1 . :f32) '(1 . :f64)
                            (cons (if nlx-p 3 2) :i32) locals))
         (buffer (make-octet-buffer)))
    ;; the structured encoding first (stackify.lisp); the dispatch loop
    ;; below is the fallback for irreducible control flow
    (when sb-vm::*wasm-stackify*
      (multiple-value-bind (body locals)
          (stackify-function-body ctx (cdr (assoc function (fctx-entry-arms ctx)))
                                  :params params :locals locals)
        (cond (body
               (return-from lower-function-body (values body locals)))
              (t
               (let ((hook sb-vm::*wasm-stackify-fallback-hook*))
                 (if hook
                     (funcall hook function)
                     (format *error-output* "~&; stackify: ~A: irreducible control flow, dispatch loop~%"
                             (wasm-function-name function))))))))
    (setf (fctx-arms ctx) arms
          (fctx-pc-local ctx) pc-local
          ;; a body may be lowered again (see LOWER-FUNCTIONS)
          (wasm-function-patches function) '()
          (wasm-function-type-patches function) '())
    ;; a function with non-local entries remembers its frame in $fp: the
    ;; CFP register belongs to whoever was running when the unwind began
    (when nlx-p
      (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+)   ; global.get thread
      (buffer-byte buffer #x28) (buffer-byte buffer 2)                    ; i32.load
      (buffer-uleb128 buffer (* sb-vm::cfp-offset sb-vm::n-word-bytes))
      (buffer-byte buffer #x21) (buffer-uleb128 buffer (+ pc-local 2)))   ; local.set $fp
    ;; the register cache: the registers this function uses, from the area
    (emit-reload buffer ctx (prologue-reload-mask params))
    ;; the arm to start at: $pc is 0 unless the start is another arm or a
    ;; caller of the same component chose one through the entry-arm global
    (cond ((wasm-function-entry-arm-p function)
           (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-entry-arm+) ; global.get
           (buffer-byte buffer #x04) (buffer-byte buffer #x7F)                 ; if (result i32)
           (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-entry-arm+)
           (buffer-byte buffer #x41) (buffer-sleb128 buffer 1)
           (buffer-byte buffer #x6B)                                           ; i32.sub
           (buffer-byte buffer #x05)                                           ; else
           (buffer-byte buffer #x41) (buffer-sleb128 buffer start-arm)
           (buffer-byte buffer #x0B)                                           ; end
           (buffer-byte buffer #x21) (buffer-uleb128 buffer pc-local)          ; local.set $pc
           (buffer-byte buffer #x41) (buffer-sleb128 buffer 0)
           (buffer-byte buffer #x24) (buffer-uleb128 buffer +global-entry-arm+)) ; global.set
          ((/= start-arm 0)
           (buffer-byte buffer #x41) (buffer-sleb128 buffer start-arm)
           (buffer-byte buffer #x21) (buffer-uleb128 buffer pc-local)))
    ;; loop $L [block $H try_table], then the arm blocks, outermost first
    (buffer-byte buffer #x03) (buffer-byte buffer +empty-block-type+)
    (let ((*open* (list :loop)))
      (when nlx-p
        (buffer-byte buffer #x02) (buffer-byte buffer +empty-block-type+) ; block $H
        (push :handler *open*)
        (buffer-byte buffer #x1F) (buffer-byte buffer +empty-block-type+) ; try_table
        (buffer-uleb128 buffer 1)
        (buffer-byte buffer #x00)                                        ; catch
        (buffer-uleb128 buffer sb-vm::+tag-lisp-unwind+)
        (buffer-uleb128 buffer 0)                                        ; -> $H
        (push :try *open*))
      (loop for i from (1- n) downto 0
            do (buffer-byte buffer #x02) (buffer-byte buffer +empty-block-type+)
               (push (list :arm i) *open*))
      ;; dispatcher
      (buffer-byte buffer #x20) (buffer-uleb128 buffer pc-local) ; local.get $pc
      (buffer-byte buffer #x0E)                                  ; br_table
      (buffer-uleb128 buffer n)
      (dotimes (i n) (buffer-uleb128 buffer i))
      (buffer-uleb128 buffer (1- n))
      ;; the arms
      (dolist (arm arms)
        (buffer-byte buffer #x0B)                                ; end of block B(index)
        (pop *open*)
        (let ((position (arm-start arm)))
          (dolist (note (remove-if-not (lambda (note)
                                         (and (<= (arm-start arm) (control-note-posn note))
                                              (< (control-note-posn note) (arm-end arm))))
                                       notes))
            (emit-arm-bytes buffer ctx position (control-note-posn note))
            (setf position (control-note-posn note))
            (emit-note-lowering buffer note ctx)
            (incf position +control-note-bytes+))
          (emit-arm-bytes buffer ctx position (arm-end arm))
          (when (arm-chunk-end-p arm)
            (chunk-exit buffer arm ctx))))
      (when nlx-p
        (buffer-byte buffer #x0B)                                ; end of try_table
        (pop *open*)
        (buffer-byte buffer #x0B)                                ; end of block $H
        (pop *open*)
        (emit-nlx-handler buffer pc-local ctx)))
    (buffer-byte buffer #x0B)                                    ; end of loop
    (buffer-byte buffer #x00)                                    ; unreachable
    (buffer-byte buffer #x0B)                                    ; end of function
    (values (coerce buffer '(simple-array (unsigned-byte 8) (*)))
            all-locals)))

;;; Lower one code range as a single function (level-0 tests).
(defun lower-code-range (segment start end &key (params '()) (locals '()))
  "A code range as a function without parameters (the level-0 tests):
its 32 register locals are all locals."
  (let* ((function (make-wasm-function :env :test :index 0 :start start
                                       :chunks (list (cons start end))))
         (ctx (make-fctx :bytes (sb-assem:segment-contents-as-vector segment)
                         :functions (list function)
                         :function-base sb-vm::+n-runtime-imports+
                         :asm-patches '()
                         :type-fixups '()
                         :function function))
         (notes (remove-if-not (lambda (note) (range-contains-p (cons start end) (control-note-posn note)))
                               (segment-control-notes segment))))
    (assign-arms function (list (cons start end)) notes notes)
    (setf (wasm-function-reg-mask function)
          (register-mask (segment-register-uses segment) (list (cons start end))))
    (lower-function-body ctx :params params :locals locals)))

(defun register-mask (uses ranges)
  "The bit mask of the registers USES ((position . register)) touch
within RANGES."
  (let ((mask 0))
    (loop for (position . register) in uses
          when (some (lambda (r) (range-contains-p r position)) ranges)
          do (setf mask (logior mask (ash 1 register))))
    mask))

;;;; Codegen interface
;;;;
;;;; GENERATE-CODE calls WASM-NOTE-COMPONENT after assembling a component.
;;;; When *WASM-COMPONENT-HOOK* is bound to a function, it receives the
;;;; component's WASM-FUNCTIONs (in module order, bodies filled in), the
;;;; names of the assembly routines the code calls, and the names of the
;;;; unimplemented VOPs it used, so that a test rig or the fasl dumper can
;;;; build a module.

;;; Placeholder generators (see VOP-NOT-YET-IMPLEMENTED in macros.lisp)
;;; count their uses in SB-VM::*WASM-UNIMPLEMENTED* and collect the VOP
;;; names of the component being generated in
;;; SB-VM::*WASM-COMPONENT-UNIMPLEMENTED*, which WASM-NOTE-COMPONENT hands
;;; to the hook. SB-VM::*WASM-STRICT-VOPS* turns a missing generator into
;;; an error.
(defvar sb-vm::*wasm-unimplemented* (make-hash-table :test 'eq))
(defvar sb-vm::*wasm-component-unimplemented* '())
(defvar sb-vm::*wasm-strict-vops* nil
  "When true, a missing generator is an error instead of UNREACHABLE.")

;;; (label . environment) of every block, in emission order; bound by
;;; GENERATE-CODE.
(defvar sb-vm::*wasm-block-labels* '())

(defvar *wasm-component-hook* nil)

(defun elsewhere-chunks-for (notes chunks)
  "The elsewhere chunks ((start . end) ...) reached by NOTES, transitively."
  (let ((result '()))
    (labels ((visit (chunk)
               (unless (member chunk result)
                 (push chunk result)
                 (dolist (note notes)
                   (when (range-contains-p chunk (control-note-posn note))
                     (reach note)))))
             (reach (note)
               (dolist (label (note-targets note))
                 (let ((chunk (find (sb-assem:label-position label) chunks :key #'car)))
                   (when chunk (visit chunk))))))
      (dolist (note notes) (reach note)))
    (nreverse result)))

(defun segment-assembly-routines (segment &optional local)
  "The assembly routines the code of SEGMENT calls, in order of first
use, except those defined in the segment itself (LOCAL, a list of
names)."
  (let ((names '()))
    (dolist (note (reverse (sb-assem::segment-fixup-notes segment)))
      (let ((fixup (sb-c::fixup-note-fixup note)))
        (when (and (eq (sb-c::fixup-flavor fixup) :assembly-routine)
                   (not (member (sb-c::fixup-name fixup) local)))
          (pushnew (sb-c::fixup-name fixup) names))))
    (nreverse names)))

(defun assembly-routine-patches (segment routines base functions)
  "Position -> function index for every :assembly-routine fixup: an
import at BASE + its position in ROUTINES, or one of FUNCTIONS when the
routine is defined in the segment itself."
  (loop for note in (sb-assem::segment-fixup-notes segment)
        for fixup = (sb-c::fixup-note-fixup note)
        when (eq (sb-c::fixup-flavor fixup) :assembly-routine)
        collect (let* ((name (sb-c::fixup-name fixup))
                       (local (find name functions :key #'wasm-function-env)))
                  (cons (sb-c::fixup-note-position note)
                        (cons (if local
                                  (+ base (length routines) (wasm-function-index local))
                                  (+ base (position name routines)))
                              name)))))

(defun elsewhere-chunks (segment asmstream)
  (let* ((elsewhere (sb-assem:label-position (sb-assem::asmstream-elsewhere-label asmstream)))
         (labels (sort (remove-duplicates
                        (remove-if-not (lambda (p) (>= p elsewhere))
                                       (mapcar #'sb-assem:label-position
                                               (remove-if-not #'sb-assem:label-p
                                                              (sb-assem::segment-annotations segment)))))
                       #'<)))
    ;; elsewhere chunks run from one elsewhere label to the next; the
    ;; last label is the end-of-text label ASSEMBLE-SECTIONS emits
    (values (loop for (start next) on labels when next collect (cons start next))
            elsewhere)))

(defun lower-functions (functions segment notes chunks asm-routines &key block-labels)
  "Fill in the bodies of FUNCTIONS (WASM-FUNCTION structs with their
chunks), returning them. BLOCK-LABELS are the labels of the compiler's
blocks (EMIT-NOTE-LOWERING)."
  (let* ((base (+ sb-vm::+n-runtime-imports+ (length asm-routines)))
         (uses (segment-register-uses segment))
         (ctx (make-fctx :bytes (sb-assem:segment-contents-as-vector segment)
                         :functions functions
                         :function-base base
                         :block-labels block-labels
                         :asm-patches (assembly-routine-patches
                                       segment asm-routines sb-vm::+n-runtime-imports+
                                       functions)
                         :type-fixups (function-type-fixups segment)
                         :fixups (loader-fixups segment))))
    ;; ranges, notes and arms of every function first: a cross-function
    ;; branch needs the callee's arms
    (dolist (function functions)
      (let* ((own-notes (remove-if-not
                         (lambda (note)
                           (some (lambda (chunk) (range-contains-p chunk (control-note-posn note)))
                                 (wasm-function-chunks function)))
                         notes))
             (elsewhere (elsewhere-chunks-for own-notes chunks))
             (ranges (append (wasm-function-chunks function) elsewhere))
             (all-notes (remove-if-not
                         (lambda (note)
                           (some (lambda (r) (range-contains-p r (control-note-posn note))) ranges))
                         notes)))
        (assign-arms function ranges all-notes notes)
        ;; the parameter registers always (EMIT-FLUSH)
        (setf (wasm-function-reg-mask function)
              (logior (register-mask uses ranges) +lisp-param-register-mask+))))
    ;; the arms other than a start that another function enters
    (setf (fctx-entry-arms ctx) (component-entry-arms ctx))
    ;; then the bodies: a body that enters another function at an arm
    ;; other than its start marks the callee (ENTRY-ARM-P), whose prologue
    ;; must then read the entry-arm global, so callees are lowered after
    ;; their callers when a body has to be redone
    (let ((pending (copy-list functions)))
      (loop while pending
            do (let ((function (pop pending))
                     (marked (remove-if-not #'wasm-function-entry-arm-p functions)))
                 (setf (fctx-function ctx) function)
                 (multiple-value-bind (body locals) (lower-function-body ctx)
                   (setf (wasm-function-body function) body
                         (wasm-function-locals function) locals))
                 ;; a function marked by this body that was already lowered
                 ;; without the prologue is lowered again
                 (dolist (f (remove-if-not #'wasm-function-entry-arm-p functions))
                   (when (and (not (member f marked)) (wasm-function-body f)
                              (not (member f pending)))
                     (setf pending (append pending (list f))))))))
    functions))

(defun wasm-component-functions (ir2-component segment asmstream block-labels)
  "The functions of a compiled component: one per environment, in order
of their first block. Returns (values functions assembly-routine-names)."
  (multiple-value-bind (chunks elsewhere) (elsewhere-chunks segment asmstream)
    (let* ((blocks (sort (loop for (label . env) in block-labels
                               collect (cons (sb-assem:label-position label) env))
                         #'< :key #'car))
           (entries (sb-c::ir2-component-entries ir2-component))
           (functions '()))
      ;; chunks per environment
      (loop for ((position . env) . rest) on blocks
            for next = (if rest (car (first rest)) elsewhere)
            do (let ((function (find env functions :key #'wasm-function-env)))
                 (cond ((null function)
                        (push (make-wasm-function
                               :env env
                               :start position
                               :entry (find-if (lambda (e)
                                                 (= (sb-assem:label-position (sb-c::entry-info-offset e))
                                                    position))
                                               entries)
                               :chunks (list (cons position next)))
                              functions))
                       ((= (cdr (first (wasm-function-chunks function))) position)
                        ;; contiguous with the previous chunk
                        (setf (cdr (first (wasm-function-chunks function))) next))
                       (t
                        (push (cons position next) (wasm-function-chunks function))))))
      (setf functions (nreverse functions))
      (loop for function in functions
            for i from 0
            do (setf (wasm-function-index function) i
                     (wasm-function-chunks function) (nreverse (wasm-function-chunks function))))
      ;; an external entry point starts after its simple-fun header,
      ;; wherever that block was emitted within the environment; the
      ;; header (and the alignment padding before it) is data, not code
      (dolist (entry entries)
        (let* ((label (sb-assem:label-position (sb-c::entry-info-offset entry)))
               (position (+ label (* sb-vm:simple-fun-insts-offset sb-vm::n-word-bytes)))
               (function (find-if (lambda (f)
                                    (some (lambda (chunk) (or (range-contains-p chunk label)
                                                              (= (car chunk) label)))
                                          (wasm-function-chunks f)))
                                  functions)))
          (when function
            (setf (wasm-function-entry function) entry
                  (wasm-function-start function) position)
            (dolist (chunk (wasm-function-chunks function))
              (when (and (<= (car chunk) label) (< (car chunk) position))
                (setf (car chunk) (min position (cdr chunk))))))))
      (let ((asm-routines (segment-assembly-routines segment)))
        (values (lower-functions functions segment (segment-control-notes segment) chunks asm-routines
                                 :block-labels (mapcar #'car block-labels))
                asm-routines)))))

(defun sb-vm::wasm-note-component (ir2-component segment asmstream block-labels)
  "Lower the component; returns its Wasm code blob (SERIALIZE-WASM-CODE)
for the fasl dumper, after handing the functions to *WASM-COMPONENT-HOOK*."
  (let ((unimplemented sb-vm::*wasm-component-unimplemented*))
    (setf sb-vm::*wasm-component-unimplemented* '())
    (multiple-value-bind (functions asm-routines)
        (wasm-component-functions ir2-component segment asmstream block-labels)
      (when *wasm-component-hook*
        (funcall *wasm-component-hook* ir2-component functions asm-routines unimplemented))
      (serialize-wasm-code functions (sb-c::ir2-component-entries ir2-component)))))

;;;; Assembly routines
;;;;
;;;; ASSEMBLE-FILE hands the assembled segment and the routine entry
;;;; points to WASM-NOTE-ASSEMBLY-ROUTINES; each routine becomes a
;;;; function whose code runs from its label to the next routine's, with
;;;; the same lowering as compiled code.

(defvar *wasm-assembly-hook* nil)

(defun sb-vm::wasm-note-assembly-routines (segment entry-points)
  "ENTRY-POINTS is the assembler's list of (name label offset). Returns
the routines' Wasm code blob for the fasl dumper."
  (progn
    (let* (;; the code ends at the end-of-text label ASSEMBLE-SECTIONS
           ;; emits before the trailer (whose bytes are not code)
           (end (reduce #'max
                        (mapcar #'sb-assem:label-position
                                (remove-if-not #'sb-assem:label-p
                                               (sb-assem::segment-annotations segment)))
                        :initial-value 0))
           (points (sort (loop for (name label) in entry-points
                               collect (cons (sb-assem:label-position label) name))
                         #'< :key #'car))
           (functions (loop for ((position . name) . rest) on points
                            for i from 0
                            collect (make-wasm-function
                                     :env name :index i :start position
                                     :chunks (list (cons position (if rest (car (first rest)) end))))))
           (asm-routines (segment-assembly-routines segment (mapcar #'cdr points))))
      (lower-functions functions segment (segment-control-notes segment) '() asm-routines)
      (when *wasm-assembly-hook*
        (funcall *wasm-assembly-hook* functions asm-routines))
      (serialize-wasm-code functions '()))))

;;;; Modules for compiled code
;;;;
;;;; Every module the backend emits has the same import list, so that the
;;;; runtime import indices in macros.lisp and the global indices below
;;;; are fixed: memory, the shared function table, the thread pointer
;;;; global, the table base global (where this module's functions are
;;;; installed), the unwind tag, then the runtime entry points in the
;;;; order of +IMPORT-...+, then the assembly routines the code calls
;;;; (imported from the core module as "lisp" NAME).

(defun make-lisp-module (&key asm-routines)
  (let ((m (make-wasm-module)))
    ;; the Lisp function type is type index 0 (+LISP-FUNCTION-TYPE-INDEX+)
    (wasm-type-index m +lisp-function-params+ +lisp-function-results+)
    (wasm-import-memory m "env" "memory" 1)
    (wasm-import-table m "env" "__indirect_function_table" :funcref 0)
    (wasm-import-global m "env" "thread" :i32 nil)
    (wasm-import-global m "env" "table_base" :i32 nil)
    (wasm-import-tag m "env" "lisp_unwind" '())
    (wasm-import-function m "env" "internal_error" '(:i32 :i32 :i32) '())
    (wasm-import-function m "env" "alloc" '(:i32) '(:i32))
    (wasm-import-function m "env" "alloc_list" '(:i32) '(:i32))
    (wasm-import-function m "env" "pending_interrupt" '() '())
    ;; the entry-arm global (+GLOBAL-ENTRY-ARM+), after the two imported globals
    (let ((index (wasm-add-global m :i32 t (i32-const-expression 0))))
      (aver (= index +global-entry-arm+)))
    (dolist (name asm-routines)
      (wasm-import-function m "lisp" (string-downcase name)
                            +lisp-function-params+ +lisp-function-results+))
    m))

(defun patch-foreign-cells (function cells)
  "Resolve the function's :FOREIGN patches whose names CELLS (an alist
name -> address) knows: the linkage cells of the differential rig's
mini-runtime (tests/wasm/minirt.c)."
  (loop for (offset kind operand) in (wasm-function-patches function)
        for cell = (and (eq kind :foreign) (assoc operand cells :test #'string=))
        when cell
        do (patch-fixed-leb128 (wasm-function-body function) offset (cdr cell) t)))

(defun add-lisp-functions (module functions &key export foreign-cells)
  "Add FUNCTIONS (WASM-FUNCTION structs, in index order) to MODULE and
install them in the shared table at table_base, in the same order. With
EXPORT, also export each by name; FOREIGN-CELLS resolves :FOREIGN
patches (PATCH-FOREIGN-CELLS)."
  (let ((indices (loop for function in functions
                       for name = (wasm-function-name function)
                       do (patch-type-indices module function)
                          (patch-foreign-cells function foreign-cells)
                       collect (wasm-add-function module +lisp-function-params+
                                                  +lisp-function-results+
                                                  (wasm-function-locals function)
                                                  (wasm-function-body function)
                                                  :name name
                                                  :export (and export (string-downcase name))))))
    (wasm-add-elements module 0 (global-get-expression +global-table-base+) indices)
    indices))


;;;; Code blobs
;;;;
;;;; A fasl carries, after each code component (and after the assembler
;;;; routines), the component's lowered Wasm functions in this format,
;;;; which genesis reads to build the core module and the loader reads
;;;; to build a module of its own (doc/wasm-port/02-design.md, 2.2):
;;;;
;;;;   "WC" u8 version
;;;;   uleb n-functions, then per function:
;;;;     name (uleb length, bytes)
;;;;     uleb n-local-declarations, then per declaration: uleb count, valtype
;;;;     uleb body-length, body
;;;;     uleb n-patches, then per patch: u8 kind, uleb body-offset, operand
;;;;       kind 0 :function              uleb function index (in this blob)
;;;;       kind 1 :assembly-routine      name
;;;;       kind 2 :type                  uleb n, valtypes, uleb n, valtypes
;;;;       kind 3 :assembly-routine-entry name
;;;;       kind 4 :foreign               name
;;;;       kind 5 :foreign-dataref       name
;;;;       kind 6 :coverage              uleb index
;;;;       kind 7 :layout-id             the layout's classoid name, PACKAGE::NAME
;;;;   uleb n-entries, then per simple-fun (in code object order): uleb
;;;;     index of its function
;;;;
;;;; Every patched immediate is a fixed five-byte LEB128: unsigned for
;;;; kinds 0-2 (call, return_call, call_indirect operands), signed for
;;;; kinds 3-6 (i32.const).

(defconstant +wasm-code-version+ 1)

(defparameter *patch-kinds*
  '((:function . 0) (:assembly-routine . 1) (:type . 2) (:assembly-routine-entry . 3)
    (:foreign . 4) (:foreign-dataref . 5) (:coverage . 6) (:layout-id . 7)))

(defun patch-kind-signed-p (kind)
  (member kind '(:assembly-routine-entry :foreign :foreign-dataref :coverage :layout-id)))

(defun patch-fixed-leb128 (body offset value signed)
  "Overwrite the five-byte LEB128 immediate at OFFSET of BODY with VALUE."
  (let ((value (if signed
                   (if (>= value (ash 1 31)) (- value (ash 1 32)) value)
                   (logand value #xFFFFFFFF))))
    (dotimes (i 4)
      (setf (aref body (+ offset i)) (logior (logand value #x7F) #x80))
      (setf value (ash value -7)))
    (setf (aref body (+ offset 4)) (logand value #x7F))))

(defun serialize-wasm-code (functions entries)
  "The blob for FUNCTIONS (WASM-FUNCTION structs, in index order);
ENTRIES are the component's entry-infos in code object order."
  (let ((b (make-octet-buffer)))
    (buffer-byte b (char-code #\W)) (buffer-byte b (char-code #\C))
    (buffer-byte b +wasm-code-version+)
    (buffer-uleb128 b (length functions))
    (dolist (f functions)
      (buffer-name b (wasm-function-name f))
      (buffer-uleb128 b (length (wasm-function-locals f)))
      (loop for (count . type) in (wasm-function-locals f)
            do (buffer-uleb128 b count) (buffer-valtype b type))
      (buffer-uleb128 b (length (wasm-function-body f)))
      (buffer-octets b (wasm-function-body f))
      (let ((patches (reverse (wasm-function-patches f))))
        (buffer-uleb128 b (length patches))
        (loop for (offset kind operand) in patches
              do (buffer-byte b (cdr (assoc kind *patch-kinds*)))
                 (buffer-uleb128 b offset)
                 (ecase kind
                   ((:function :coverage) (buffer-uleb128 b operand))
                   ((:assembly-routine :assembly-routine-entry :foreign :foreign-dataref :layout-id)
                    (buffer-name b operand))
                   (:type
                    (destructuring-bind (params results) operand
                      (buffer-uleb128 b (length params))
                      (dolist (v params) (buffer-valtype b v))
                      (buffer-uleb128 b (length results))
                      (dolist (v results) (buffer-valtype b v))))))))
    (buffer-uleb128 b (length entries))
    (dolist (entry entries)
      (let ((f (find entry functions :key #'wasm-function-entry)))
        (unless f (error "entry ~S has no function" entry))
        (buffer-uleb128 b (wasm-function-index f))))
    (coerce b '(simple-array (unsigned-byte 8) (*)))))

(defun valtype-of-byte (byte)
  (ecase byte (#x7F :i32) (#x7E :i64) (#x7D :f32) (#x7C :f64) (#x70 :funcref) (#x6F :externref)))

(defun parse-wasm-code (octets)
  "Read a blob back: (values functions entry-function-indices)."
  (let ((pos 0))
    (labels ((u8 () (prog1 (aref octets pos) (incf pos)))
             (uleb ()
               (let ((result 0) (shift 0))
                 (loop (let ((byte (u8)))
                         (setf result (logior result (ash (logand byte #x7F) shift)))
                         (incf shift 7)
                         (unless (logbitp 7 byte) (return result))))))
             (name ()
               (let* ((n (uleb))
                      (string (make-string n)))
                 (dotimes (i n string) (setf (char string i) (code-char (u8))))))
             (octets (n)
               (let ((v (make-array n :element-type '(unsigned-byte 8))))
                 (replace v octets :start2 pos)
                 (incf pos n)
                 v))
             (valtypes () (let ((n (uleb))) (loop repeat n collect (valtype-of-byte (u8))))))
      (unless (and (= (u8) (char-code #\W)) (= (u8) (char-code #\C)) (= (u8) +wasm-code-version+))
        (error "not a Wasm code blob"))
      (let* ((n (uleb))
             (functions
               (loop for i below n
                     collect (let* ((fname (name))
                                    (locals (loop repeat (uleb)
                                                  collect (let ((count (uleb)))
                                                            (cons count (valtype-of-byte (u8))))))
                                    (body (octets (uleb)))
                                    (patches
                                      (loop repeat (uleb)
                                            collect (let* ((kind (car (rassoc (u8) *patch-kinds*)))
                                                           (offset (uleb)))
                                                      (list offset kind
                                                            (ecase kind
                                                              ((:function :coverage) (uleb))
                                                              ((:assembly-routine :assembly-routine-entry
                                                                :foreign :foreign-dataref :layout-id)
                                                               (name))
                                                              (:type (let* ((params (valtypes))
                                                                            (results (valtypes)))
                                                                       (list params results)))))))))
                               (make-wasm-function :index i :name-slot fname :locals locals
                                                   :body body :patches patches))))
             (entries (loop repeat (uleb) collect (uleb))))
        (values functions entries)))))
