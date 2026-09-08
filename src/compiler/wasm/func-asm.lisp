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
;;; the runtime entry points (+IMPORT-...+ in macros.lisp), which precede
;;; the assembly routine imports in the function index space
(defconstant sb-vm::+n-runtime-imports+ 4)
;;; the type index of the Lisp function signature
(defconstant sb-vm::+lisp-function-type-index+ 0)
;;; the tag index of the unwind tag
(defconstant sb-vm::+tag-lisp-unwind+ 0)
;;; thread-area word holding the block an unwind is targeting
(defconstant sb-vm::+thread-unwind-target-offset+ 448)

;;; Every Lisp function (no parameters) starts with three scratch locals
;;; a VOP may use to reorder operands, since Wasm has no swap: a value
;;; already on the operand stack can be parked while the address it is
;;; stored to is pushed (see CALL-OUT in c-call.lisp).
(defconstant sb-vm::+scratch-i32-local+ 0)
(defconstant sb-vm::+scratch-f32-local+ 1)
(defconstant sb-vm::+scratch-f64-local+ 2)
(defconstant sb-vm::+n-scratch-locals+ 3)

;;; The uniform signature of a Lisp entry point.
(defconstant-eqx +lisp-function-params+ '() #'equal)
(defconstant-eqx +lisp-function-results+ '(:i32) #'equal)

;;;; Byte ranges and arms

(defun range-contains-p (range position)
  (and (<= (car range) position) (< position (cdr range))))

(defun note-targets (note)
  "The labels a control note may branch to within its function."
  (ecase (control-note-kind note)
    ((:jump :jump-if :nlx-entry :label-index) (list (control-note-labels note)))
    (:jump-table (append (control-note-labels note) (list (control-note-data note))))
    ((:func-begin :func-end :call-label :tail-call-label) '())))

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
  "The arm that starts at POSITION (a branch target)."
  (or (find position arms :key #'arm-start)
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
  (type-patches '()))

(defun wasm-function-name (function)
  (let ((entry (wasm-function-entry function))
        (env (wasm-function-env function)))
    (cond (entry (princ-to-string (sb-c::entry-info-name entry)))
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
        (candidates (remove position (fctx-functions ctx)
                            :key #'wasm-function-start :test-not #'=)))
    (flet ((code-at-p (function)
             (some (lambda (chunk) (< (car chunk) (cdr chunk)))
                   (wasm-function-chunks function))))
      (or (find-if (lambda (f) (and (not (eq f current)) (code-at-p f))) candidates)
          (find-if (lambda (f) (not (eq f current))) candidates)))))

(defun function-of-label (ctx label)
  (let* ((position (sb-assem:label-position label))
         (function (function-starting-at ctx position)))
    (unless function
      (error "label at ~D is not the start of a function" position))
    (+ (fctx-function-base ctx) (wasm-function-index function))))

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

(defun emit-note-lowering (buffer note ctx)
  (let ((arms (fctx-arms ctx))
        (pc-local (fctx-pc-local ctx)))
    (flet ((target-arm (label)
             (arm-index (arm-at arms (sb-assem:label-position label))))
           (local-target-p (label)
             (find (sb-assem:label-position label) arms :key #'arm-start)))
      (ecase (control-note-kind note)
        (:jump
         (let ((label (control-note-labels note)))
           (cond ((local-target-p label)
                  (emit-set-pc-and-loop buffer pc-local (target-arm label)))
                 (t
                  ;; a tail local call into another function
                  (buffer-byte buffer #x12)                          ; return_call
                  (buffer-uleb128 buffer (function-of-label ctx label))))))
        (:jump-if
         ;; condition is on the operand stack
         (buffer-byte buffer #x04) (buffer-byte buffer +empty-block-type+) ; if
         (let ((*open* (cons :if *open*)))
           (emit-set-pc-and-loop buffer pc-local (target-arm (control-note-labels note))))
         (buffer-byte buffer #x0B))                                       ; end
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
         (buffer-byte buffer #x10)                                        ; call
         (buffer-uleb128 buffer (function-of-label ctx (control-note-labels note))))
        (:tail-call-label
         (buffer-byte buffer #x12)                                        ; return_call
         (buffer-uleb128 buffer (function-of-label ctx (control-note-labels note))))
        (:label-index
         (buffer-byte buffer #x41)                                        ; i32.const
         (buffer-sleb128 buffer (target-arm (control-note-labels note))))
        ((:func-begin :func-end :nlx-entry)
         nil)))))

;;; The exception handler of a function with non-local entries: the
;;; unwind routine stored the target block in the thread and threw
;;; LISP_UNWIND. A block of this frame (its CFP slot equals CFP) is
;;; entered through the dispatcher at the arm index the block holds;
;;; any other block belongs to a caller, so the exception is rethrown.
(defun emit-nlx-handler (buffer pc-local)
  (flet ((load-target ()
           (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+) ; global.get thread
           (buffer-byte buffer #x28) (buffer-byte buffer 2)                ; i32.load align=2
           (buffer-uleb128 buffer sb-vm::+thread-unwind-target-offset+)))
    (load-target)
    (buffer-byte buffer #x28) (buffer-byte buffer 2)
    (buffer-uleb128 buffer (* sb-vm::unwind-block-cfp-slot sb-vm::n-word-bytes))
    (buffer-byte buffer #x20) (buffer-uleb128 buffer (+ pc-local 2))      ; local.get $fp
    (buffer-byte buffer #x47)                                             ; i32.ne
    (buffer-byte buffer #x04) (buffer-byte buffer +empty-block-type+)     ; if
    (buffer-byte buffer #x08) (buffer-uleb128 buffer sb-vm::+tag-lisp-unwind+) ; throw
    (buffer-byte buffer #x0B)                                             ; end
    (load-target)
    (buffer-byte buffer #x28) (buffer-byte buffer 2)
    (buffer-uleb128 buffer (* sb-vm::unwind-block-entry-pc-slot sb-vm::n-word-bytes))
    (buffer-byte buffer #x21) (buffer-uleb128 buffer pc-local)            ; local.set $pc
    (buffer-byte buffer #x0C) (buffer-uleb128 buffer (depth-of :loop))))  ; br $L

(defun chunk-exit (buffer arm ctx)
  "Code after the last arm of a chunk: the next block in emission order
belongs to another function. Either it is that function's first block
(a tail local call that IR2 lowered to a fall-through) or the arm ended
with a return or a jump and this is not reached."
  (let ((next (function-continuing-at ctx (arm-end arm))))
    (cond (next
           (buffer-byte buffer #x12)                                      ; return_call
           (buffer-uleb128 buffer (+ (fctx-function-base ctx) (wasm-function-index next))))
          (t
           (buffer-byte buffer #x00)))))                                  ; unreachable

(defun emit-arm-bytes (buffer ctx from to)
  "Copy segment bytes [FROM, TO), patching assembly-routine fixups and
recording the function-type fixups by their offset in the body."
  (let ((bytes (fctx-bytes ctx))
        (position from))
    (loop while (< position to)
          do (let ((patch (cdr (assoc position (fctx-asm-patches ctx))))
                   (type (cdr (assoc position (fctx-type-fixups ctx)))))
               (cond (patch
                      (emit-fixed-uleb128-32 buffer patch)
                      (incf position 5))
                     (type
                      (push (list (fill-pointer buffer) (first type) (second type))
                            (wasm-function-type-patches (fctx-function ctx)))
                      (loop repeat 5 do (buffer-byte buffer (aref bytes position)) (incf position)))
                     (t
                      (buffer-byte buffer (aref bytes position))
                      (incf position)))))))

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

(defun lower-function-body (ctx ranges notes &key (params '()) (locals '()))
  "Lower the code in RANGES ((start . end) ...) with the control NOTES
inside them into a Wasm function body. Returns the body octets (ending
with END) and the local declarations ((count . type) ...)."
  (let* ((target-positions (loop for note in notes
                                 append (mapcar #'sb-assem:label-position (note-targets note))))
         ;; a jump to another function's start is not a local target
         (local-targets (remove-if-not
                         (lambda (p) (some (lambda (r) (or (range-contains-p r p) (= p (cdr r))))
                                           ranges))
                         target-positions))
         (arms (compute-arms ranges local-targets))
         (n (length arms))
         ;; the three scratch locals VOPs may use (+SCRATCH-I32-LOCAL+ and
         ;; friends in macros.lisp), then $pc
         (pc-local (+ (length params) sb-vm::+n-scratch-locals+))
         (nlx-p (some (lambda (note) (eq (control-note-kind note) :nlx-entry)) notes))
         ;; the scratch locals, $pc, the jump-table scratch local and (with
         ;; non-local entries) $fp precede the caller's locals
         (all-locals (list* '(1 . :i32) '(1 . :f32) '(1 . :f64)
                            (cons (if nlx-p 3 2) :i32) locals))
         (buffer (make-octet-buffer)))
    (setf (fctx-arms ctx) arms
          (fctx-pc-local ctx) pc-local)
    (dolist (p target-positions)
      (unless (or (member p local-targets)
                  (function-starting-at ctx p))
        (error "branch target at ~D is outside the function" p)))
    ;; a function with non-local entries remembers its frame in $fp: the
    ;; CFP register belongs to whoever was running when the unwind began
    (when nlx-p
      (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+)   ; global.get thread
      (buffer-byte buffer #x28) (buffer-byte buffer 2)                    ; i32.load
      (buffer-uleb128 buffer (* sb-vm::cfp-offset sb-vm::n-word-bytes))
      (buffer-byte buffer #x21) (buffer-uleb128 buffer (+ pc-local 2)))   ; local.set $fp
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
        (emit-nlx-handler buffer pc-local)))
    (buffer-byte buffer #x0B)                                    ; end of loop
    (buffer-byte buffer #x00)                                    ; unreachable
    (buffer-byte buffer #x0B)                                    ; end of function
    (values (coerce buffer '(simple-array (unsigned-byte 8) (*)))
            all-locals)))

;;; Lower one code range as a single function (level-0 tests).
(defun lower-code-range (segment start end &key (params '()) (locals '()))
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
    (lower-function-body ctx (list (cons start end)) notes :params params :locals locals)))

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
                        (if local
                            (+ base (length routines) (wasm-function-index local))
                            (+ base (position name routines)))))))

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

(defun lower-functions (functions segment notes chunks asm-routines)
  "Fill in the bodies of FUNCTIONS (WASM-FUNCTION structs with their
chunks), returning them."
  (let* ((base (+ sb-vm::+n-runtime-imports+ (length asm-routines)))
         (ctx (make-fctx :bytes (sb-assem:segment-contents-as-vector segment)
                         :functions functions
                         :function-base base
                         :asm-patches (assembly-routine-patches
                                       segment asm-routines sb-vm::+n-runtime-imports+
                                       functions)
                         :type-fixups (function-type-fixups segment))))
    (dolist (function functions)
      (setf (fctx-function ctx) function)
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
        (multiple-value-bind (body locals) (lower-function-body ctx ranges all-notes)
          (setf (wasm-function-body function) body
                (wasm-function-locals function) locals))))
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
      (let ((asm-routines (segment-assembly-routines segment)))
        (values (lower-functions functions segment (segment-control-notes segment) chunks asm-routines)
                asm-routines)))))

(defun sb-vm::wasm-note-component (ir2-component segment asmstream block-labels)
  (let ((unimplemented sb-vm::*wasm-component-unimplemented*))
    (setf sb-vm::*wasm-component-unimplemented* '())
    (when *wasm-component-hook*
      (multiple-value-bind (functions asm-routines)
          (wasm-component-functions ir2-component segment asmstream block-labels)
        (funcall *wasm-component-hook* ir2-component functions asm-routines unimplemented)))))

;;;; Assembly routines
;;;;
;;;; ASSEMBLE-FILE hands the assembled segment and the routine entry
;;;; points to WASM-NOTE-ASSEMBLY-ROUTINES; each routine becomes a
;;;; function whose code runs from its label to the next routine's, with
;;;; the same lowering as compiled code.

(defvar *wasm-assembly-hook* nil)

(defun sb-vm::wasm-note-assembly-routines (segment entry-points)
  "ENTRY-POINTS is the assembler's list of (name label offset)."
  (when *wasm-assembly-hook*
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
      (funcall *wasm-assembly-hook*
               (lower-functions functions segment (segment-control-notes segment) '() asm-routines)
               asm-routines))))

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
    (dolist (name asm-routines)
      (wasm-import-function m "lisp" (string-downcase name)
                            +lisp-function-params+ +lisp-function-results+))
    m))

(defun add-lisp-functions (module functions &key export)
  "Add FUNCTIONS (WASM-FUNCTION structs, in index order) to MODULE and
install them in the shared table at table_base, in the same order. With
EXPORT, also export each by name."
  (let ((indices (loop for function in functions
                       for name = (wasm-function-name function)
                       do (patch-type-indices module function)
                       collect (wasm-add-function module +lisp-function-params+
                                                  +lisp-function-results+
                                                  (wasm-function-locals function)
                                                  (wasm-function-body function)
                                                  :name name
                                                  :export (and export (string-downcase name))))))
    (wasm-add-elements module 0 (global-get-expression +global-table-base+) indices)
    indices))
