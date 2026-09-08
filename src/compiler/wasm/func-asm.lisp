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
;;;; The operand stack must be empty at every label and at every
;;;; pseudo-instruction except for the value a JUMP-IF or JUMP-TABLE
;;;; consumes; the VOPs guarantee this.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-WASM-ASM")

;;;; Byte ranges and arms

(defun range-contains-p (range position)
  (and (<= (car range) position) (< position (cdr range))))

(defun note-targets (note)
  "The labels a control note may branch to."
  (ecase (control-note-kind note)
    (:jump (list (control-note-labels note)))
    (:jump-if (list (control-note-labels note)))
    (:jump-table (append (control-note-labels note) (list (control-note-data note))))
    ((:func-begin :func-end) '())))

;;; An arm is a byte range of the segment; arms are numbered in the
;;; order they are emitted, which is range order then position order.
(defstruct (arm (:copier nil))
  (index 0 :type index)
  (start 0 :type index)
  (end 0 :type index))

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
              do (push (make-arm :index index :start start :end (or next (cdr range))) arms)
                 (incf index))))
    (nreverse arms)))

(defun arm-at (arms position)
  "The arm that starts at POSITION (a branch target)."
  (or (find position arms :key #'arm-start)
      (error "no arm starts at position ~D" position)))

;;;; Emission

(defvar *open* '()
  "The open control constructs at the current point, innermost first.
Each element is a tag; :loop marks the dispatch loop.")

(defun depth-of (tag)
  (or (position tag *open*)
      (error "control construct ~S is not open" tag)))

(defun emit-set-pc-and-loop (buffer pc-local arm-index)
  (buffer-byte buffer #x41) (buffer-sleb128 buffer arm-index) ; i32.const arm
  (buffer-byte buffer #x21) (buffer-uleb128 buffer pc-local)  ; local.set $pc
  (buffer-byte buffer #x0C) (buffer-uleb128 buffer (depth-of :loop))) ; br $L

(defun emit-note-lowering (buffer note arms pc-local)
  (flet ((target-arm (label)
           (arm-index (arm-at arms (sb-assem:label-position label)))))
    (ecase (control-note-kind note)
      (:jump
       (emit-set-pc-and-loop buffer pc-local (target-arm (control-note-labels note))))
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
      ((:func-begin :func-end)
       nil))))

(defun wasm-function-body (segment entry-label end
                           &key (params '()) (results '(:i32)) (locals '())
                                elsewhere-chunks)
  "Lower the function whose code starts at ENTRY-LABEL and ends at byte
position END in SEGMENT, plus any ELSEWHERE-CHUNKS ((start . end) ...)
that belong to it, into a Wasm function body. Returns the body octets
(ending with END) and the local declarations ((count . type) ...)."
  (declare (ignore results))
  (let* ((bytes (sb-assem:segment-contents-as-vector segment))
         (ranges (cons (cons (sb-assem:label-position entry-label) end) elsewhere-chunks))
         (notes (remove-if-not (lambda (note)
                                 (some (lambda (r) (range-contains-p r (control-note-posn note)))
                                       ranges))
                               (segment-control-notes segment)))
         (target-positions (loop for note in notes
                                 append (mapcar #'sb-assem:label-position (note-targets note))))
         (arms (compute-arms ranges target-positions))
         (n (length arms))
         (pc-local (length params))
         ;; $pc and the jump-table scratch local precede the caller's locals
         (all-locals (cons (cons 2 :i32) locals))
         (buffer (make-octet-buffer)))
    (dolist (p target-positions)
      (unless (some (lambda (r) (or (range-contains-p r p) (= p (cdr r)))) ranges)
        (error "branch target at ~D is outside the function" p)))
    ;; loop $L, then the arm blocks, outermost first
    (buffer-byte buffer #x03) (buffer-byte buffer +empty-block-type+)
    (let ((*open* (list :loop)))
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
            (loop while (< position (control-note-posn note))
                  do (buffer-byte buffer (aref bytes position)) (incf position))
            (emit-note-lowering buffer note arms pc-local)
            (incf position +control-note-bytes+))
          (loop while (< position (arm-end arm))
                do (buffer-byte buffer (aref bytes position)) (incf position)))))
    (buffer-byte buffer #x0B)                                    ; end of loop
    (buffer-byte buffer #x00)                                    ; unreachable
    (buffer-byte buffer #x0B)                                    ; end of function
    (values (coerce buffer '(simple-array (unsigned-byte 8) (*)))
            all-locals)))

;;;; Codegen interface
;;;;
;;;; GENERATE-CODE calls WASM-NOTE-COMPONENT after assembling a component.
;;;; When *WASM-COMPONENT-HOOK* is bound to a function, it receives the
;;;; component's functions as a list of (entry-info . body-octets) pairs
;;;; plus the locals, so that a test rig or the fasl dumper can build a
;;;; module. Each entry (XEP) of the component is one Wasm function; its
;;;; code runs from its entry label to the next entry label, or to the
;;;; start of the elsewhere section, plus the elsewhere chunks its own
;;;; branches reach.

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

(defun wasm-component-functions (ir2-component segment asmstream)
  (let* ((entries (sort (copy-list (sb-c::ir2-component-entries ir2-component)) #'<
                        :key (lambda (e) (sb-assem:label-position (sb-c::entry-info-offset e)))))
         (elsewhere (sb-assem:label-position (sb-assem::asmstream-elsewhere-label asmstream)))
         (labels (sort (remove-if-not (lambda (p) (>= p elsewhere))
                                      (mapcar #'sb-assem:label-position
                                              (remove-if-not #'sb-assem:label-p
                                                             (sb-assem::segment-annotations segment))))
                       #'<))
         ;; elsewhere chunks run from one elsewhere label to the next; the
         ;; last label is the end-of-text label ASSEMBLE-SECTIONS emits
         (chunks (loop for (start next) on (remove-duplicates labels)
                       when next collect (cons start next)))
         (notes (segment-control-notes segment)))
    (loop for (entry next) on entries
          collect (let* ((label (sb-c::entry-info-offset entry))
                         (start (sb-assem:label-position label))
                         (end (if next
                                  (sb-assem:label-position (sb-c::entry-info-offset next))
                                  elsewhere))
                         (own-notes (remove-if-not
                                     (lambda (note) (range-contains-p (cons start end)
                                                                      (control-note-posn note)))
                                     notes)))
                    (multiple-value-bind (body locals)
                        (wasm-function-body segment label end
                                            :elsewhere-chunks (elsewhere-chunks-for own-notes chunks))
                      (list entry body locals))))))

(defun sb-vm::wasm-note-component (ir2-component segment asmstream)
  (let ((unimplemented sb-vm::*wasm-component-unimplemented*))
    (setf sb-vm::*wasm-component-unimplemented* '())
    (when *wasm-component-hook*
      (funcall *wasm-component-hook* ir2-component
               (wasm-component-functions ir2-component segment asmstream)
               unimplemented))))

;;;; Modules for compiled code
;;;;
;;;; Every module the backend emits has the same import list, so that the
;;;; runtime import indices in macros.lisp and the global indices below
;;;; are fixed: memory, the shared function table, the thread pointer
;;;; global, the table base global (where this module's functions are
;;;; installed), then the runtime entry points in the order of
;;;; +IMPORT-...+.

(defconstant +global-thread+ 0)
(defconstant +global-table-base+ 1)

(defun make-lisp-module ()
  (let ((m (make-wasm-module)))
    (wasm-import-memory m "env" "memory" 1)
    (wasm-import-table m "env" "__indirect_function_table" :funcref 0)
    (wasm-import-global m "env" "thread" :i32 nil)
    (wasm-import-global m "env" "table_base" :i32 nil)
    (wasm-import-function m "env" "internal_error" '(:i32 :i32 :i32) '())
    (wasm-import-function m "env" "alloc" '(:i32) '(:i32))
    (wasm-import-function m "env" "alloc_list" '(:i32) '(:i32))
    (wasm-import-function m "env" "pending_interrupt" '() '())
    m))

;;; The uniform signature of a Lisp entry point.
(defconstant-eqx +lisp-function-params+ '() #'equal)
(defconstant-eqx +lisp-function-results+ '(:i32) #'equal)

(defun add-lisp-functions (module functions)
  "Add FUNCTIONS, a list of (name body locals), to MODULE and install
them in the shared table at table_base. Returns the list of positions of
the functions relative to table_base."
  (let ((indices (loop for (name body locals) in functions
                       collect (wasm-add-function module +lisp-function-params+
                                                  +lisp-function-results+
                                                  locals body :name name))))
    (wasm-add-elements module 0 (global-get-expression +global-table-base+) indices)
    (loop for i from 0 below (length indices) collect i)))
