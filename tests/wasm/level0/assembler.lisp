;;;; Level-0 tests for the WebAssembly backend: the instruction encoder,
;;;; the control-flow pseudo-instructions and the module writer.
;;;;
;;;; Runs inside the cross-compiler image (obj/xbuild/wasm/xc.core), so
;;;; no runtime is needed. Modules are written to an output directory and
;;;; tests/wasm/run-level0.sh validates them with wasm-tools and executes
;;;; the exported functions under wasmtime, comparing against the expected
;;;; results written to expected.txt.

(in-package "SB-WASM-ASM")

(defvar *out-dir*)
(defvar *failures* 0)
(defvar *checks* 0)
(defvar *expected* nil)

(defun check (name ok)
  (incf *checks*)
  (unless ok
    (incf *failures*)
    (format t "~&FAIL ~A~%" name))
  ok)

(defun expect (module function args result)
  "Record that MODULE's exported FUNCTION applied to ARGS must return RESULT."
  (push (format nil "~A ~A ~{~A ~}=> ~A" module function args result) *expected*))

(defun assemble-body (thunk)
  "Assemble THUNK's instructions followed by END; return the octets."
  (values (assemble-octets thunk)))

(defmacro body (&body forms)
  `(assemble-body (lambda () ,@forms)))

(defun bytes-of (thunk)
  "Assemble THUNK's instructions alone and return the octets as a list."
  (coerce (assemble-octets thunk :end nil) 'list))

(defun write-module (name module)
  (write-wasm-module module (format nil "~A/~A.wasm" *out-dir* name)))

;;;; T1: LEB128 and constant encodings

(defun test-leb128 ()
  (flet ((u (v) (let ((s (sb-assem:make-segment)))
                  (emit-uleb128 s v) (sb-assem:finalize-segment s)
                  (coerce (sb-assem:segment-contents-as-vector s) 'list)))
         (s (v) (let ((s (sb-assem:make-segment)))
                  (emit-sleb128 s v) (sb-assem:finalize-segment s)
                  (coerce (sb-assem:segment-contents-as-vector s) 'list))))
    (check "uleb 0" (equal (u 0) '(0)))
    (check "uleb 127" (equal (u 127) '(127)))
    (check "uleb 128" (equal (u 128) '(#x80 #x01)))
    (check "uleb 624485" (equal (u 624485) '(#xE5 #x8E #x26)))
    (check "sleb 0" (equal (s 0) '(0)))
    (check "sleb -1" (equal (s -1) '(#x7F)))
    (check "sleb 63" (equal (s 63) '(#x3F)))
    (check "sleb 64" (equal (s 64) '(#xC0 #x00)))
    (check "sleb -64" (equal (s -64) '(#x40)))
    (check "sleb -65" (equal (s -65) '(#xBF #x7F)))
    (check "sleb -123456" (equal (s -123456) '(#xC0 #xBB #x78)))
    ;; i32.const with an unsigned 32-bit value encodes as the signed
    ;; equivalent, as the spec requires
    (check "i32.const #xFFFFFFFF" (equal (bytes-of (lambda () (inst i32.const #xFFFFFFFF)))
                                        '(#x41 #x7F)))
    (check "fixed sleb 5 bytes"
           (let ((s (sb-assem:make-segment)))
             (emit-fixed-sleb128-32 s 1) (sb-assem:finalize-segment s)
             (equal (coerce (sb-assem:segment-contents-as-vector s) 'list)
                    '(#x81 #x80 #x80 #x80 #x00))))
    (check "f64.const bits" (equal (bytes-of (lambda () (inst f64.const #x3FF0000000000000)))
                                  '(#x44 0 0 0 0 0 0 #xF0 #x3F)))))

;;;; T2: a two-argument function, executed by wasmtime

(defun test-add ()
  (let ((m (make-wasm-module)))
    (wasm-add-function m '(:i32 :i32) '(:i32) '()
                       (body (inst local.get 0) (inst local.get 1) (inst i32.add))
                       :name "add" :export "add")
    (write-module "add" m)
    (expect "add" "add" '(2 3) 5)
    (expect "add" "add" '(-7 7) 0)))

;;;; T3: memory, arithmetic, conversions and structured control flow

(defun test-arith-memory ()
  (let ((m (make-wasm-module)))
    (wasm-add-memory m 1 :export "memory")
    ;; helper: square(x)
    (let ((square (wasm-add-function m '(:i32) '(:i32) '()
                                     (body (inst local.get 0) (inst local.get 0) (inst i32.mul))
                                     :name "square")))
      (wasm-add-table m :funcref 2)
      (wasm-add-elements m 0 (i32-const-expression 1) (list square))
      (let ((sq-type (wasm-type-index m '(:i32) '(:i32))))
        ;; compute a value from many instruction kinds; the expected result is
        ;; computed alongside in Lisp
        (let* ((expected
                 (let* ((a 100000) (b 7)
                        (s (+ (* a b) (- a b)))
                        (s (logand s #xFFFF))
                        (s (+ s (mod 12345 (ash 1 8)) (ash 3 4) (- 1000000 (* 1000000 (floor 1000000 65536) 0))))
                        (s (logand s #x7FFFFFFF)))
                   s))
               (function
                 (body
                   ;; store and load i32/i64/f32/f64 with offsets
                   (inst i32.const 0) (inst i32.const 12345) (inst i32.store 8)
                   (inst i32.const 0) (inst i64.const 1000000) (inst i64.store 16)
                   (inst i32.const 0) (inst f64.const #x4059000000000000) (inst f64.store 24) ; 100.0
                   (inst i32.const 0) (inst f32.const #x40E00000) (inst f32.store 32) ; 7.0
                   ;; a*b + (a-b), masked to 16 bits
                   (inst i32.const 100000) (inst i32.const 7) (inst i32.mul)
                   (inst i32.const 100000) (inst i32.const 7) (inst i32.sub)
                   (inst i32.add)
                   (inst i32.const #xFFFF) (inst i32.and)
                   ;; + (12345 mod 256) via load8
                   (inst i32.const 0) (inst i32.load8_u 8) (inst i32.add)
                   ;; + 3 << 4
                   (inst i32.const 3) (inst i32.const 4) (inst i32.shl) (inst i32.add)
                   ;; + trunc(f64 100.0) * 0 + wrap(i64 1000000) - i64 part: 1000000 - 1000000*(1000000/65536)*0
                   (inst i32.const 0) (inst f64.load 24) (inst i32.trunc_f64_s)
                   (inst i32.const 0) (inst i32.mul) (inst i32.add)
                   (inst i32.const 0) (inst i64.load 16) (inst i32.wrap_i64) (inst i32.add)
                   ;; structured control flow: loop 3 times subtracting 0
                   (inst i32.const 3)
                   (inst local.set 0)
                   (inst block)
                   (inst loop)
                   (inst local.get 0) (inst i32.eqz) (inst br_if 1)
                   (inst local.get 0) (inst i32.const 1) (inst i32.sub) (inst local.set 0)
                   (inst br 0)
                   (inst end)
                   (inst end)
                   ;; if/else selects 0
                   (inst local.get 0) (inst if :i32) (inst i32.const 99) (inst else) (inst i32.const 0) (inst end)
                   (inst i32.add)
                   ;; call_indirect square(0) through the table adds 0
                   (inst i32.const 0) (inst i32.const 1) (inst call_indirect sq-type 0) (inst i32.add)
                   ;; sign-extension and saturating truncation of 7.0 - 7
                   (inst i32.const 0) (inst f32.load 32) (inst i32.trunc_sat_f32_s)
                   (inst i32.const 7) (inst i32.sub) (inst i32.extend8_s) (inst i32.add)
                   ;; br_table: index 1 of (0 1 2) with default → adds 0
                   (inst block) (inst block) (inst block)
                   (inst i32.const 1) (inst br_table '(0 1) 2)
                   (inst end) (inst end) (inst end)
                   ;; select: choose 0
                   (inst i32.const 5) (inst i32.const 0) (inst i32.const 0) (inst select) (inst i32.add)
                   ;; mask to a positive i32
                   (inst i32.const #x7FFFFFFF) (inst i32.and))))
          (wasm-add-function m '() '(:i32) '((1 . :i32)) function :name "compute" :export "compute")
          (expect "arith" "compute" '() expected))))
    (write-module "arith" m)))

;;;; T4: exception handling and tail calls

(defun test-eh-tail ()
  (let* ((m (make-wasm-module))
         (tag (wasm-add-tag m '()))
         ;; count(n, acc): tail-recursive countdown
         (count (wasm-add-function m '(:i32 :i32) '(:i32) '()
                                   (body
                                     (inst local.get 0) (inst i32.eqz)
                                     (inst if) (inst local.get 1) (inst return) (inst end)
                                     (inst local.get 0) (inst i32.const 1) (inst i32.sub)
                                     (inst local.get 1) (inst i32.const 1) (inst i32.add)
                                     (inst return_call 0))
                                   :name "count")))
    (wasm-add-function m '(:i32) '(:i32) '()
                       (body (inst local.get 0) (inst i32.const 0) (inst call count))
                       :name "tail" :export "tail")
    ;; thrower: throws the tag
    (let ((thrower (wasm-add-function m '() '() '() (body (inst throw tag)) :name "thrower")))
      ;; catcher: returns 42 when the tag is caught, 0 otherwise
      (wasm-add-function m '() '(:i32) '()
                         (body
                           (inst block)                          ; $handler
                           (inst try_table nil (list (list :catch tag 0)))
                           (inst call thrower)
                           (inst i32.const 0) (inst return)
                           (inst end)
                           (inst end)
                           (inst i32.const 42))
                         :name "catcher" :export "catcher"))
    (write-module "eh" m)
    (expect "eh" "tail" '(1000000) 1000000)
    (expect "eh" "catcher" '() 42)))

;;;; T5: control pseudo-instructions record notes, emit no bytes

(defun test-control-notes ()
  ;; Labels are emitted through a section, as codegen does; %ASSEMBLE then
  ;; produces the finalized segment.
  (let* ((segment (sb-assem:make-segment))
         (section (sb-assem::make-section))
         (l1 (sb-assem:gen-label)) (l2 (sb-assem:gen-label)) (l3 (sb-assem:gen-label))
         (entry (sb-assem:gen-label)))
    (sb-assem:assemble (section)
      (inst func-begin entry :params '(:i32) :results '(:i32))
      (sb-assem:emit-label entry)
      (inst i32.const 1)
      (inst jump l2)
      (sb-assem:emit-label l1)
      (inst i32.const 2)
      (inst i32.eqz)
      (inst jump-if l3)
      (sb-assem:emit-label l2)
      (inst i32.const 3)
      (inst jump-table (list l1 l2) l3)
      (sb-assem:emit-label l3)
      (inst func-end))
    (sb-assem::%assemble segment section)
    (let ((notes (segment-control-notes segment))
          (bytes (sb-assem:segment-contents-as-vector segment)))
      (check "five notes" (= (length notes) 5))
      (check "note kinds in order"
             (equal (mapcar #'control-note-kind notes)
                    '(:func-begin :jump :jump-if :jump-table :func-end)))
      ;; 3 x (i32.const n) = 6, i32.eqz = 1, five one-byte pseudo-ops
      (check "pseudo-ops occupy one byte each" (= (length bytes) 12))
      (check "jump position after first const"
             (= (control-note-posn (second notes)) 3))
      (check "jump-if position" (= (control-note-posn (third notes)) 7))
      (check "labels used" (and (sb-assem:label-usedp l1) (sb-assem:label-usedp l2)
                                (sb-assem:label-usedp l3)))
      (check "label positions" (and (= (sb-assem:label-position l1) 4)
                                    (= (sb-assem:label-position l2) 8)
                                    (= (sb-assem:label-position l3) 11)))
      (check "jump-table data" (eq (control-note-data (fourth notes)) l3)))))

;;;; T6: fixups produce fixed-width immediates and notes

(defun test-fixups ()
  (multiple-value-bind (bytes segment)
      (assemble-octets (lambda ()
                         (inst nop)
                         (inst i32.const (sb-c:make-fixup "foo" :foreign))
                         (inst word (sb-c:make-fixup "bar" :foreign-dataref)))
                       :end nil)
    (let ((bytes (coerce bytes 'list))
          (notes (sb-assem::segment-fixup-notes segment)))
      (check "fixup bytes" (equal bytes '(#x01 #x41 #x80 #x80 #x80 #x80 #x00 0 0 0 0)))
      (unless (check "two fixup notes" (= (length notes) 2))
        (format t "~&  fixup notes: ~S~%" notes))
      (check "fixup kinds" (equal (sort (mapcar #'sb-c:fixup-note-kind notes) #'string<)
                                  '(:absolute :leb128)))
      (check "leb128 fixup position"
             (= (sb-c:fixup-note-position
                 (find :leb128 notes :key #'sb-c:fixup-note-kind))
                2)))))

;;;; T8: the function assembler lowers label streams to structured code

(defun lower-function (thunk &key params results locals)
  "Assemble THUNK's label stream through a section, then lower it. The
entry is the first label THUNK returns."
  (let* ((segment (sb-assem:make-segment))
         (section (sb-assem::make-section))
         (entry (sb-assem:assemble (section) (funcall thunk))))
    (sb-assem::%assemble segment section)
    (wasm-function-body segment entry (sb-assem::segment-final-posn segment)
                        :params params :results results :locals locals)))

(defun test-function-assembler ()
  (let ((m (make-wasm-module)))
    ;; sum 1..10 with a backward jump; locals 2 = i, 3 = acc ($pc 0, scratch 1)
    (multiple-value-bind (body locals)
        (lower-function
         (lambda ()
           (let ((entry (sb-assem:gen-label)) (head (sb-assem:gen-label))
                 (done (sb-assem:gen-label)))
             (sb-assem:emit-label entry)
             (inst i32.const 10) (inst local.set 2)
             (sb-assem:emit-label head)
             (inst local.get 2) (inst i32.eqz) (inst jump-if done)
             (inst local.get 3) (inst local.get 2) (inst i32.add) (inst local.set 3)
             (inst local.get 2) (inst i32.const 1) (inst i32.sub) (inst local.set 2)
             (inst jump head)
             (sb-assem:emit-label done)
             (inst local.get 3) (inst return)
             entry))
         :locals '((2 . :i32)))
      (wasm-add-function m '() '(:i32) locals body :name "sum10" :export "sum10"))
    ;; a three-way jump table on the parameter; $pc is local 1, scratch 2
    (multiple-value-bind (body locals)
        (lower-function
         (lambda ()
           (let ((entry (sb-assem:gen-label)) (a (sb-assem:gen-label))
                 (b (sb-assem:gen-label)) (c (sb-assem:gen-label))
                 (default (sb-assem:gen-label)))
             (sb-assem:emit-label entry)
             (inst local.get 0)
             (inst jump-table (list a b c) default)
             (sb-assem:emit-label a) (inst i32.const 10) (inst return)
             (sb-assem:emit-label b) (inst i32.const 20) (inst return)
             (sb-assem:emit-label c) (inst i32.const 30) (inst return)
             (sb-assem:emit-label default) (inst i32.const 99) (inst return)
             entry))
         :params '(:i32))
      (wasm-add-function m '(:i32) '(:i32) locals body :name "pick" :export "pick"))
    ;; a jump immediately before its own target label: the empty arm case,
    ;; and a forward jump over dead code
    (multiple-value-bind (body locals)
        (lower-function
         (lambda ()
           (let ((entry (sb-assem:gen-label)) (skip (sb-assem:gen-label))
                 (next (sb-assem:gen-label)))
             (sb-assem:emit-label entry)
             (inst jump skip)
             (inst i32.const 1) (inst return)
             (sb-assem:emit-label skip)
             (inst jump next)
             (sb-assem:emit-label next)
             (inst i32.const 7) (inst return)
             entry)))
      (wasm-add-function m '() '(:i32) locals body :name "skip" :export "skip"))
    (write-module "funcasm" m)
    (expect "funcasm" "sum10" '() 55)
    (expect "funcasm" "pick" '(0) 10)
    (expect "funcasm" "pick" '(2) 30)
    (expect "funcasm" "pick" '(7) 99)
    (expect "funcasm" "skip" '() 7)))

;;;; T7: imports, globals, data and the name section

(defun test-module-sections ()
  (let ((m (make-wasm-module)))
    (wasm-import-memory m "env" "memory" 1)
    (wasm-import-table m "env" "table" :funcref 0)
    (wasm-import-global m "env" "base" :i32 nil)
    (let ((imported (wasm-import-function m "env" "host_print" '(:i32) '())))
      (wasm-add-global m :i32 t (i32-const-expression 7) :export "g")
      (wasm-add-data m (i32-const-expression 64) (coerce #(1 2 3 4) '(simple-array (unsigned-byte 8) (*))))
      (wasm-add-data m nil (coerce #(5 6) '(simple-array (unsigned-byte 8) (*))))
      (let ((f (wasm-add-function m '() '(:i32) '()
                                  (body (inst global.get 1) (inst i32.const 64) (inst i32.load8_u 2) (inst i32.add))
                                  :name "seven_plus_three" :export "f")))
        (wasm-add-elements m 0 (global-get-expression 0) (list f))
        (check "import index precedes defined" (and (= imported 0) (= f 1)))))
    (write-module "sections" m)))

(defun run-level0 (out-dir)
  (setf *out-dir* out-dir *failures* 0 *checks* 0 *expected* nil)
  (ensure-directories-exist (format nil "~A/" out-dir))
  (test-leb128)
  (test-add)
  (test-arith-memory)
  (test-eh-tail)
  (test-control-notes)
  (test-fixups)
  (test-module-sections)
  (test-function-assembler)
  (with-open-file (s (format nil "~A/expected.txt" out-dir) :direction :output :if-exists :supersede)
    (dolist (line (reverse *expected*)) (write-line line s)))
  (format t "~&level0 lisp checks: ~D, failures: ~D~%" *checks* *failures*)
  (funcall (intern "EXIT" "HOST-SB-EXT") :code (if (zerop *failures*) 0 1)))
