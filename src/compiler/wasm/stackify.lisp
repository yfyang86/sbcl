;;;; The stackifier: structured control flow for the WebAssembly
;;;; backend (doc/wasm-port/02-design.md, 2.5, encoding 2).
;;;;
;;;; The function assembler (func-asm.lisp) splits a function into arms
;;;; (byte ranges starting at branch targets) and lowers them under a
;;;; dispatch loop. This pass builds the control-flow graph of the arms,
;;;; computes dominators, and, when the graph is reducible, emits the
;;;; arms under nested BLOCK and LOOP constructs with direct BR, BR_IF
;;;; and BR_TABLE branches, the way LLVM's CFGStackify and Ramsey's
;;;; "Beyond Relooper" do: an arm's dominator-tree children that are
;;;; branch targets each get a BLOCK ending where the child starts, a
;;;; loop header gets a LOOP around its subtree, and a branch to an arm
;;;; is a BR to the construct whose end (a block) or start (a loop) is
;;;; the arm. An irreducible graph (a loop entered other than through
;;;; its header: TAGBODY and GO can make one, so can a non-local entry
;;;; into a loop) falls back to the dispatch loop, and the fallback is
;;;; reported so that the build log counts them.
;;;;
;;;; Entries other than the function's start (a non-local entry, or a
;;;; local call from another function of the component entering at an
;;;; arm) are the successors of a virtual entry node whose code is a
;;;; BR_TABLE on $pc, the arm index; the exception handler of a function
;;;; with non-local entries sets $pc and branches to the outer loop as
;;;; before, so the arm indices keep their meaning.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-WASM-ASM")

;;;; The control-flow graph of the arms

;;; Per arm: the successors as (kind . arm-index), kind :fall (the next
;;; arm in the code), :branch (a JUMP, JUMP-IF or JUMP-TABLE note), or
;;; :entry (from the virtual entry node).
(defstruct (cfg (:copier nil))
  (n 0)                 ; the arms; the virtual entry is node N
  (succs #() :type simple-vector)
  (preds #() :type simple-vector)
  ;; the note of each :branch edge, for the poll decision
  (rpo #() :type simple-vector)      ; node -> reverse-postorder number, or NIL if unreachable
  (order '())                         ; nodes in reverse postorder
  (idom #() :type simple-vector)      ; node -> immediate dominator
  (children #() :type simple-vector)  ; node -> dominator-tree children, in rpo order
  (loop-header-p #() :type simple-vector))

(defun arm-notes (arm notes)
  (remove-if-not (lambda (note)
                   (and (<= (arm-start arm) (control-note-posn note))
                        (< (control-note-posn note) (arm-end arm))))
                 notes))

(defun build-cfg (ctx entry-arms)
  "The graph of the current function's arms; ENTRY-ARMS are the arm
indices entered from outside besides the start arm. Returns NIL when a
jump table targets another function."
  (let* ((function (fctx-function ctx))
         (arms (wasm-function-arms function))
         (notes (wasm-function-notes function))
         (n (length arms))
         (succs (make-array (1+ n) :initial-element '()))
         (preds (make-array (1+ n) :initial-element '())))
    (flet ((local-target-p (label)
             (find (sb-assem:label-position label) arms :key #'arm-start))
           (target-arm (label)
             (arm-index (arm-at arms (sb-assem:label-position label))))
           (add-edge (from kind to)
             (push (cons kind to) (aref succs from))
             (push from (aref preds to))))
      (dolist (arm arms)
        (let ((i (arm-index arm))
              (terminated nil))
          (dolist (note (arm-notes arm notes))
            (unless terminated
              (ecase (control-note-kind note)
                (:jump-if
                 (let ((label (control-note-labels note)))
                   (when (local-target-p label)
                     (add-edge i :branch (target-arm label)))))
                (:jump
                 (let ((label (control-note-labels note)))
                   (when (local-target-p label)
                     (add-edge i :branch (target-arm label))))
                 (setf terminated t))
                (:jump-table
                 (dolist (label (append (control-note-labels note)
                                        (list (control-note-data note))))
                   (unless (local-target-p label)
                     (return-from build-cfg nil))
                   (add-edge i :branch (target-arm label)))
                 (setf terminated t))
                ((:tail-call-label :terminator)
                 (setf terminated t))
                ((:call-label :label-index :func-begin :func-end :nlx-entry :flush :reload)
                 nil))))
          (unless (or terminated (arm-chunk-end-p arm))
            (add-edge i :fall (1+ i)))))
      ;; the virtual entry
      (add-edge n :entry (wasm-function-start-arm function))
      (dolist (e entry-arms)
        (unless (= e (wasm-function-start-arm function))
          (add-edge n :entry e)))
      (loop for i from 0 to n
            do (setf (aref succs i) (nreverse (aref succs i))
                     (aref preds i) (remove-duplicates (nreverse (aref preds i)))))
      (make-cfg :n n :succs succs :preds preds))))

(defun cfg-analyze (cfg)
  "Reverse postorder from the entry, dominators and loop headers.
Returns NIL when the graph is irreducible."
  (let* ((n (cfg-n cfg))
         (succs (cfg-succs cfg))
         (state (make-array (1+ n) :initial-element nil)) ; nil, :active, :done
         (postorder '()))
    ;; a depth-first walk; an edge to an :active node is a back edge
    (labels ((visit (node)
               (setf (aref state node) :active)
               (dolist (edge (aref succs node))
                 (let ((to (cdr edge)))
                   (case (aref state to)
                     ((nil) (visit to))
                     (:active nil)
                     (:done nil))))
               (setf (aref state node) :done)
               (push node postorder)))
      (visit n))
    (let* ((order postorder)               ; reverse postorder
           (rpo (make-array (1+ n) :initial-element nil)))
      (loop for node in order for k from 0 do (setf (aref rpo node) k))
      ;; dominators (Cooper, Harvey, Kennedy): the entry is its own
      (let ((idom (make-array (1+ n) :initial-element nil))
            (changed t))
        (setf (aref idom n) n)
        (flet ((intersect (a b)
                 (loop until (= a b)
                       do (loop while (> (aref rpo a) (aref rpo b)) do (setf a (aref idom a)))
                          (loop while (> (aref rpo b) (aref rpo a)) do (setf b (aref idom b))))
                 a))
          (loop while changed
                do (setf changed nil)
                   (dolist (node (rest order))
                     (let ((new nil))
                       (dolist (p (aref (cfg-preds cfg) node))
                         (when (and (aref rpo p) (aref idom p))
                           (setf new (if new (intersect p new) p))))
                       (unless (eql new (aref idom node))
                         (setf (aref idom node) new
                               changed t))))))
        ;; reducibility: every retreating edge's target dominates its source
        (let ((loop-header-p (make-array (1+ n) :initial-element nil)))
          (flet ((dominates-p (a b)
                   (loop (cond ((= a b) (return t))
                               ((= b n) (return nil))
                               (t (setf b (aref idom b)))))))
            (dolist (node order)
              (dolist (edge (aref succs node))
                (let ((to (cdr edge)))
                  (when (<= (aref rpo to) (aref rpo node))
                    (unless (dominates-p to node)
                      (return-from cfg-analyze nil))
                    (setf (aref loop-header-p to) t))))))
          (let ((children (make-array (1+ n) :initial-element '())))
            (dolist (node (reverse order))
              (unless (= node n)
                (push node (aref children (aref idom node)))))
            (setf (cfg-rpo cfg) rpo
                  (cfg-order cfg) order
                  (cfg-idom cfg) idom
                  (cfg-children cfg) children
                  (cfg-loop-header-p cfg) loop-header-p)
            cfg))))))

;;;; Emission

;;; *OPEN* (func-asm.lisp) holds the open constructs, innermost first;
;;; this pass adds (:block . arm) and (:loop . arm) entries.
(defun depth-to (arm)
  (or (position-if (lambda (entry)
                     (and (consp entry)
                          (member (car entry) '(:block :loop))
                          (eql (cdr entry) arm)))
                   *open*)
      (error "no open construct targets arm ~D" arm)))

(defun emit-branch-to (buffer ctx arm note)
  "A BR to ARM, with the loop safe point before it when the branch is a
back edge between the compiler's blocks."
  (let ((poll (and (eq (car (find-if (lambda (entry)
                                       (and (consp entry) (member (car entry) '(:block :loop))
                                            (eql (cdr entry) arm)))
                                     *open*))
                       :loop)
                   note
                   (let ((label (control-note-labels note)))
                     (or (eq (control-note-data note) :poll)
                         (member label (fctx-block-labels ctx) :test #'eq))))))
    (when poll (emit-back-edge-poll buffer ctx))
    (buffer-byte buffer #x0C) (buffer-uleb128 buffer (depth-to arm))))   ; br

(defun stackify-note (buffer note ctx cfg)
  "Lower one control note in the structured encoding."
  (let ((arms (fctx-arms ctx)))
    (flet ((local-target-p (label)
             (find (sb-assem:label-position label) arms :key #'arm-start))
           (target-arm (label)
             (arm-index (arm-at arms (sb-assem:label-position label)))))
      (ecase (control-note-kind note)
        (:jump
         (let ((label (control-note-labels note)))
           (if (local-target-p label)
               (emit-branch-to buffer ctx (target-arm label) note)
               (emit-cross-ref buffer ctx (sb-assem:label-position label) #x12))))
        (:jump-if
         (let ((label (control-note-labels note)))
           (cond ((not (local-target-p label))
                  (buffer-byte buffer #x04) (buffer-byte buffer +empty-block-type+) ; if
                  (let ((*open* (cons :if *open*)))
                    (emit-cross-ref buffer ctx (sb-assem:label-position label) #x12))
                  (buffer-byte buffer #x0B))                                    ; end
                 (t
                  (let* ((arm (target-arm label))
                        (entry (find-if (lambda (e) (and (consp e) (member (car e) '(:block :loop))
                                                         (eql (cdr e) arm)))
                                        *open*))
                        (poll (and (eq (car entry) :loop)
                                   (or (eq (control-note-data note) :poll)
                                       (member label (fctx-block-labels ctx) :test #'eq)))))
                    (cond (poll
                           (buffer-byte buffer #x04) (buffer-byte buffer +empty-block-type+) ; if
                           (let ((*open* (cons :if *open*)))
                             (emit-branch-to buffer ctx arm note))
                           (buffer-byte buffer #x0B))                           ; end
                          (t
                           (buffer-byte buffer #x0D)                            ; br_if
                           (buffer-uleb128 buffer (depth-to arm)))))))))
        (:jump-table
         ;; the index is on the operand stack
         (let* ((labels (control-note-labels note))
                (default (control-note-data note)))
           (buffer-byte buffer #x0E)                                            ; br_table
           (buffer-uleb128 buffer (length labels))
           (dolist (label labels)
             (buffer-uleb128 buffer (depth-to (target-arm label))))
           (buffer-uleb128 buffer (depth-to (target-arm default)))))
        (:call-label
         (emit-cross-ref buffer ctx (sb-assem:label-position (control-note-labels note)) #x10))
        (:tail-call-label
         (emit-cross-ref buffer ctx (sb-assem:label-position (control-note-labels note)) #x12))
        (:label-index
         (buffer-byte buffer #x41)                                              ; i32.const
         (buffer-sleb128 buffer (target-arm (control-note-labels note))))
        (:flush (emit-flush buffer ctx (control-note-data note)))
        (:reload (emit-reload buffer ctx))
        ((:func-begin :func-end :nlx-entry :terminator)
         nil))
      cfg)))

(defun emit-arm-code (buffer ctx cfg arm)
  "The code of ARM: its bytes with the notes lowered, then the chunk exit.
A note after a JUMP, JUMP-TABLE, tail call or terminator of the arm is
dead code (BUILD-CFG has no edge for it) and lowers to UNREACHABLE."
  (let ((notes (wasm-function-notes (fctx-function ctx)))
        (position (arm-start arm))
        (terminated nil))
    (dolist (note (arm-notes arm notes))
      (emit-arm-bytes buffer ctx position (control-note-posn note))
      (setf position (control-note-posn note))
      (if terminated
          (buffer-byte buffer #x00)                                             ; unreachable
          (stackify-note buffer note ctx cfg))
      (when (member (control-note-kind note) '(:jump :jump-table :tail-call-label :terminator))
        (setf terminated t))
      (incf position +control-note-bytes+))
    (emit-arm-bytes buffer ctx position (arm-end arm))
    (when (arm-chunk-end-p arm)
      (chunk-exit buffer arm ctx))))

(defun fall-through-successor (cfg node)
  (cdr (find :fall (aref (cfg-succs cfg) node) :key #'car)))

(defun emit-tree (buffer ctx cfg node pc-local)
  "Emit NODE's code and its dominator subtree (see the file comment)."
  (let* ((n (cfg-n cfg))
         (arms (fctx-arms ctx))
         (children (sort (copy-list (aref (cfg-children cfg) node)) #'<
                         :key (lambda (c) (aref (cfg-rpo cfg) c))))
         (entry-succs (and (= node n) (mapcar #'cdr (aref (cfg-succs cfg) node))))
         (fall (if (= node n)
                   ;; the virtual entry falls into the start arm when it is
                   ;; the only entry; with several, every entry gets a block
                   (and (= (length entry-succs) 1) (first entry-succs))
                   (fall-through-successor cfg node)))
         ;; the fall-through successor is placed right after this node when
         ;; nothing else reaches it, not even a branch of this node (a
         ;; conditional skip to the next arm needs the block)
         (ft-child (and fall (member fall children)
                        (= (length (aref (cfg-preds cfg) fall)) 1)
                        (not (find-if (lambda (edge) (and (eq (car edge) :branch)
                                                          (eql (cdr edge) fall)))
                                      (aref (cfg-succs cfg) node)))
                        fall))
         (merge-children (remove ft-child children))
         (loop-p (and (< node n) (aref (cfg-loop-header-p cfg) node))))
    (when loop-p
      (buffer-byte buffer #x03) (buffer-byte buffer +empty-block-type+)          ; loop
      (push (cons :loop node) *open*))
    (dolist (c (reverse merge-children))
      (buffer-byte buffer #x02) (buffer-byte buffer +empty-block-type+)          ; block
      (push (cons :block c) *open*))
    (cond ((= node n)
           ;; the virtual entry: several entries dispatch on $pc
           (when merge-children
             (buffer-byte buffer #x20) (buffer-uleb128 buffer pc-local)         ; local.get $pc
             (buffer-byte buffer #x0E)                                          ; br_table
             (buffer-uleb128 buffer n)
             (dotimes (i n)
               (buffer-uleb128 buffer (if (member i entry-succs)
                                          (depth-to i)
                                          (depth-to :unreachable))))
             (buffer-uleb128 buffer (depth-to :unreachable))))
          (t
           (emit-arm-code buffer ctx cfg (nth node arms))
           ;; the fall-through edge, when its target is not placed next
           (when (and fall (not (eql fall ft-child)))
             (emit-branch-to buffer ctx fall nil))))
    ;; the virtual entry with one entry and no code falls into it as well
    (when (and (= node n) fall (not (eql fall ft-child)))
      (emit-branch-to buffer ctx fall nil))
    (when ft-child
      (emit-tree buffer ctx cfg ft-child pc-local))
    (dolist (c merge-children)
      (buffer-byte buffer #x0B)                                                 ; end (block c)
      (pop *open*)
      (emit-tree buffer ctx cfg c pc-local))
    (when loop-p
      (buffer-byte buffer #x0B)                                                 ; end (loop)
      (pop *open*))))

(defun stackify-function-body (ctx entry-arms &key (params '()) (locals '()))
  "Lower the function of CTX with structured control flow; ENTRY-ARMS
are the arms entered from other functions of the component. Returns
(values body locals), or NIL when the control flow is irreducible."
  (let* ((function (fctx-function ctx))
         (notes (wasm-function-notes function))
         (arms (wasm-function-arms function))
         (start-arm (wasm-function-start-arm function))
         (pc-local (+ (length params) sb-vm::+n-register-locals+ sb-vm::+n-scratch-locals+))
         (nlx-p (some (lambda (note) (eq (control-note-kind note) :nlx-entry)) notes))
         (nlx-entries (loop for note in notes
                            when (eq (control-note-kind note) :nlx-entry)
                            collect (arm-index (arm-at arms (sb-assem:label-position
                                                             (control-note-labels note))))))
         (entries (remove-duplicates (append entry-arms nlx-entries)))
         (all-locals (list* (cons sb-vm::+n-register-locals+ :i32)
                            '(1 . :i32) '(1 . :f32) '(1 . :f64)
                            (cons (if nlx-p 3 2) :i32) locals))
         (cfg (build-cfg ctx entries)))
    (unless (and cfg (cfg-analyze cfg))
      (return-from stackify-function-body nil))
    (setf (fctx-arms ctx) arms
          (fctx-pc-local ctx) pc-local
          (wasm-function-patches function) '()
          (wasm-function-type-patches function) '())
    (let ((buffer (make-octet-buffer))
          (multiple-entries (rest (aref (cfg-succs cfg) (cfg-n cfg)))))
      (when nlx-p
        (buffer-byte buffer #x23) (buffer-uleb128 buffer +global-thread+)   ; global.get thread
        (buffer-byte buffer #x28) (buffer-byte buffer 2)                    ; i32.load
        (buffer-uleb128 buffer (* sb-vm::cfp-offset sb-vm::n-word-bytes))
        (buffer-byte buffer #x21) (buffer-uleb128 buffer (+ pc-local 2)))   ; local.set $fp
      ;; the register cache: the registers this function uses, from the area
      (emit-reload buffer ctx)
      ;; $pc: the start arm, or the arm a caller chose (the prologue of
      ;; the dispatch encoding, which the entry dispatch reads)
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
            (multiple-entries
             (buffer-byte buffer #x41) (buffer-sleb128 buffer start-arm)
             (buffer-byte buffer #x21) (buffer-uleb128 buffer pc-local)))
      (let ((*open* '()))
        ;; loop $L [block $H try_table] block $U, then the tree
        (when nlx-p
          (buffer-byte buffer #x03) (buffer-byte buffer +empty-block-type+)   ; loop $L
          (push :loop *open*)
          (buffer-byte buffer #x02) (buffer-byte buffer +empty-block-type+)   ; block $H
          (push :handler *open*)
          (buffer-byte buffer #x1F) (buffer-byte buffer +empty-block-type+)   ; try_table
          (buffer-uleb128 buffer 1)
          (buffer-byte buffer #x00)                                           ; catch
          (buffer-uleb128 buffer sb-vm::+tag-lisp-unwind+)
          (buffer-uleb128 buffer 0)                                           ; -> $H
          (push :try *open*))
        (buffer-byte buffer #x02) (buffer-byte buffer +empty-block-type+)     ; block $U
        (push (cons :block :unreachable) *open*)
        (emit-tree buffer ctx cfg (cfg-n cfg) pc-local)
        (buffer-byte buffer #x0B)                                             ; end $U
        (pop *open*)
        (buffer-byte buffer #x00)                                             ; unreachable
        (when nlx-p
          (buffer-byte buffer #x0B)                                           ; end of try_table
          (pop *open*)
          (buffer-byte buffer #x0B)                                           ; end of block $H
          (pop *open*)
          (emit-nlx-handler buffer pc-local ctx)
          (buffer-byte buffer #x0B)                                           ; end of loop
          (pop *open*)
          (buffer-byte buffer #x00)))                                         ; unreachable
      (buffer-byte buffer #x0B)                                               ; end of function
      (values (coerce buffer '(simple-array (unsigned-byte 8) (*)))
              all-locals))))

;;;; The entry arms of every function of a component

(defun component-entry-arms (ctx)
  "For each function, the arms other than its start that a local call, a
tail local call or a cross-function jump of the component enters: an
alist function -> arm indices. The callees are marked ENTRY-ARM-P."
  (let ((result '()))
    (dolist (function (fctx-functions ctx))
      (dolist (note (wasm-function-notes function))
        (let ((label (case (control-note-kind note)
                       ((:call-label :tail-call-label :jump :jump-if)
                        (control-note-labels note)))))
          (when label
            (let ((position (sb-assem:label-position label)))
              ;; a target of another function
              (unless (find position (wasm-function-arms function) :key #'arm-start)
                (let* ((callee (function-containing ctx position))
                       (arm (arm-at (wasm-function-arms callee) position)))
                  (unless (= (arm-index arm) (wasm-function-start-arm callee))
                    (setf (wasm-function-entry-arm-p callee) t)
                    (pushnew (arm-index arm) (cdr (or (assoc callee result)
                                                      (first (push (list callee) result)))))))))))))
    result))
