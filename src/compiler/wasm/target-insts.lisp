;;;; Target-only assembler support for the WebAssembly backend: the
;;;; bytecode decoder behind DISASSEMBLE (doc/wasm-port/02-design.md,
;;;; 2.10).
;;;;
;;;; A function's code is not in its code object: the simple-fun's self
;;;; slot holds the table index of its Wasm function, which lives in the
;;;; core module (the file next to the core) or in a module compiled at
;;;; run time (*WASM-LOADED-MODULES*, (table-base . bytes), newest
;;;; first). DISASSEMBLE-FUNCTION finds the module, its code section and
;;;; the body at the index, and prints the instructions with two offsets:
;;;; within the body, and within the module, which is what the host's
;;;; trap backtraces report.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-WASM-ASM")

;;;; Reading a module

(defstruct (wasm-module-info (:conc-name wmi-))
  bytes                                 ; the module
  (table-base 0)                        ; from the sbcl.core.table section
  (table-count 0)
  (n-imported-functions 0)
  bodies                                ; vector of (start . end) offsets, code section order
  ;; the function index at each table slot from the base (the module's
  ;; element segment), or NIL when the slots hold the functions in order
  (table-functions nil)
  names)                                ; hash table: function index -> name, if any

(defun read-uleb128 (bytes pos)
  "The unsigned LEB128 at POS; second value the position after it."
  (let ((result 0) (shift 0))
    (loop (let ((byte (aref bytes pos)))
            (incf pos)
            (setf result (logior result (ash (logand byte #x7f) shift)))
            (incf shift 7)
            (when (zerop (logand byte #x80))
              (return (values result pos)))))))

(defun read-sleb128 (bytes pos)
  "The signed LEB128 at POS; second value the position after it."
  (let ((result 0) (shift 0) (byte 0))
    (loop (setf byte (aref bytes pos))
          (incf pos)
          (setf result (logior result (ash (logand byte #x7f) shift)))
          (incf shift 7)
          (when (zerop (logand byte #x80))
            (return (values (if (logtest byte #x40) (- result (ash 1 shift)) result)
                            pos))))))

(defun parse-wasm-module (bytes)
  (declare (type (simple-array (unsigned-byte 8) (*)) bytes))
  (unless (and (> (length bytes) 8)
               (= (aref bytes 0) 0) (= (aref bytes 1) #x61)
               (= (aref bytes 2) #x73) (= (aref bytes 3) #x6d))
    (error "not a Wasm module"))
  (let ((info (make-wasm-module-info :bytes bytes :names (make-hash-table)))
        (pos 8)
        (end (length bytes)))
    (loop while (< pos end)
          do (let ((id (aref bytes pos)))
               (multiple-value-bind (size p) (read-uleb128 bytes (1+ pos))
                 (let ((section-end (+ p size)))
                   (case id
                     (0                 ; custom
                      (multiple-value-bind (len q) (read-uleb128 bytes p)
                        (let ((name (map 'string #'code-char (subseq bytes q (+ q len))))
                              (q (+ q len)))
                          (cond ((string= name "sbcl.core.table")
                                 (setf (wmi-table-base info)
                                       (logior (aref bytes q) (ash (aref bytes (+ q 1)) 8)
                                               (ash (aref bytes (+ q 2)) 16) (ash (aref bytes (+ q 3)) 24))
                                       (wmi-table-count info)
                                       (logior (aref bytes (+ q 4)) (ash (aref bytes (+ q 5)) 8)
                                               (ash (aref bytes (+ q 6)) 16) (ash (aref bytes (+ q 7)) 24))))
                                ((string= name "name")
                                 (parse-name-section info bytes q section-end))))))
                     (2                 ; import
                      (multiple-value-bind (n q) (read-uleb128 bytes p)
                        (dotimes (i n)
                          (multiple-value-bind (len q2) (read-uleb128 bytes q)
                            (setf q (+ q2 len)))
                          (multiple-value-bind (len q2) (read-uleb128 bytes q)
                            (setf q (+ q2 len)))
                          (let ((kind (aref bytes q)))
                            (incf q)
                            (ecase kind
                              (0 (incf (wmi-n-imported-functions info))
                                 (setf q (nth-value 1 (read-uleb128 bytes q))))
                              (1 (incf q) ; reftype
                                 (setf q (parse-limits bytes q)))
                              (2 (setf q (parse-limits bytes q)))
                              (3 (incf q 2)) ; valtype, mutability
                              (4 (incf q)   ; tag attribute
                                 (setf q (nth-value 1 (read-uleb128 bytes q)))))))))
                     (9                 ; element: one active segment of
                                        ; function indices, the way
                                        ; module.lisp writes it (flags 2:
                                        ; explicit table, funcref kind; or
                                        ; flags 0). wasm-opt may renumber
                                        ; the functions, so the table is
                                        ; read rather than assumed
                      (multiple-value-bind (n q) (read-uleb128 bytes p)
                        (when (and (= n 1) (member (aref bytes q) '(0 2)))
                          (let ((flags (aref bytes q))
                                (q (1+ q)))
                            (when (= flags 2)
                              (setf q (nth-value 1 (read-uleb128 bytes q)))) ; table index
                            ;; the offset expression: global.get or
                            ;; i32.const up to its END
                            (loop until (= (aref bytes q) #x0B)
                                  do (incf q))
                            (incf q)
                            (when (= flags 2) (incf q)) ; elemkind
                            (multiple-value-bind (count q2) (read-uleb128 bytes q)
                              (let ((functions (make-array count)))
                                (dotimes (i count)
                                  (multiple-value-bind (index q3) (read-uleb128 bytes q2)
                                    (setf (aref functions i) index q2 q3)))
                                (setf (wmi-table-functions info) functions)))))))
                     (10                ; code
                      (multiple-value-bind (n q) (read-uleb128 bytes p)
                        (let ((bodies (make-array n)))
                          (dotimes (i n)
                            (multiple-value-bind (size q2) (read-uleb128 bytes q)
                              (setf (aref bodies i) (cons q2 (+ q2 size))
                                    q (+ q2 size))))
                          (setf (wmi-bodies info) bodies)))))
                   (setf pos section-end)))))
    info))

(defun parse-limits (bytes pos)
  (let ((flags (aref bytes pos)))
    (setf pos (nth-value 1 (read-uleb128 bytes (1+ pos))))
    (when (logtest flags 1)
      (setf pos (nth-value 1 (read-uleb128 bytes pos))))
    pos))

(defun parse-name-section (info bytes pos end)
  (loop while (< pos end)
        do (let ((id (aref bytes pos)))
             (multiple-value-bind (size p) (read-uleb128 bytes (1+ pos))
               (when (= id 1)         ; function names
                 (multiple-value-bind (n q) (read-uleb128 bytes p)
                   (dotimes (i n)
                     (multiple-value-bind (index q2) (read-uleb128 bytes q)
                       (multiple-value-bind (len q3) (read-uleb128 bytes q2)
                         (setf (gethash index (wmi-names info))
                               (sb-ext:octets-to-string (subseq bytes q3 (+ q3 len))
                                                        :external-format :utf-8)
                               q (+ q3 len)))))))
               (setf pos (+ p size))))))

;;;; Finding the module of a function

(defvar *core-module-info* nil
  "The parsed core module, read on first use.")

(defun core-module-pathname ()
  (let ((core sb-ext:*core-pathname*))
    (make-pathname :name (concatenate 'string (pathname-name core) "-core")
                   :type "wasm" :defaults core)))

(defun read-file-octets (pathname)
  (with-open-file (in pathname :element-type '(unsigned-byte 8))
    (let ((bytes (make-array (file-length in) :element-type '(unsigned-byte 8))))
      (read-sequence bytes in)
      bytes)))

(defun core-module-info ()
  (or *core-module-info*
      (setf *core-module-info* (parse-wasm-module (read-file-octets (core-module-pathname))))))

(defun module-info-for-table-index (index)
  "The parsed module holding table index INDEX: a run-time module, or the core module."
  (let ((entry (find-if (lambda (entry) (<= (car entry) index)) sb-vm::*wasm-loaded-modules*)))
    (if entry
        (let ((info (parse-wasm-module (coerce (cdr entry) '(simple-array (unsigned-byte 8) (*))))))
          (if (< index (+ (wmi-table-base info) (wmi-table-count info)))
              info
              (core-module-info)))
        (core-module-info))))

(defun simple-fun-table-index (fun)
  "The table index of a simple-fun: its self slot."
  (let ((fun (sb-kernel:%fun-fun fun)))
    (sb-sys:with-pinned-objects (fun)
      (sb-sys:sap-ref-word (sb-sys:int-sap (sb-kernel:get-lisp-obj-address fun))
                           (- (ash sb-vm:simple-fun-self-slot sb-vm:word-shift)
                              sb-vm:fun-pointer-lowtag)))))

;;;; Decoding

;;; opcode -> (name . immediates), immediates one of
;;; :none :blocktype :u32 :u32x2 :br-table :memarg :i32 :i64 :f32 :f64 :try-table :select-t
(defparameter *opcode-table*
  (let ((table (make-array 256 :initial-element nil)))
    (flet ((def (opcode name imm) (setf (aref table opcode) (cons name imm))))
      (def #x00 "unreachable" :none) (def #x01 "nop" :none)
      (def #x02 "block" :blocktype) (def #x03 "loop" :blocktype) (def #x04 "if" :blocktype)
      (def #x05 "else" :none) (def #x0B "end" :none)
      (def #x0C "br" :u32) (def #x0D "br_if" :u32) (def #x0E "br_table" :br-table)
      (def #x0F "return" :none) (def #x10 "call" :u32) (def #x11 "call_indirect" :u32x2)
      (def #x12 "return_call" :u32) (def #x13 "return_call_indirect" :u32x2)
      (def #x08 "throw" :u32) (def #x0A "throw_ref" :none) (def #x1F "try_table" :try-table)
      (def #x1A "drop" :none) (def #x1B "select" :none) (def #x1C "select" :select-t)
      (def #x20 "local.get" :u32) (def #x21 "local.set" :u32) (def #x22 "local.tee" :u32)
      (def #x23 "global.get" :u32) (def #x24 "global.set" :u32)
      (def #x25 "table.get" :u32) (def #x26 "table.set" :u32)
      (loop for (opcode name) in '((#x28 "i32.load") (#x29 "i64.load") (#x2A "f32.load") (#x2B "f64.load")
                                   (#x2C "i32.load8_s") (#x2D "i32.load8_u") (#x2E "i32.load16_s") (#x2F "i32.load16_u")
                                   (#x30 "i64.load8_s") (#x31 "i64.load8_u") (#x32 "i64.load16_s") (#x33 "i64.load16_u")
                                   (#x34 "i64.load32_s") (#x35 "i64.load32_u")
                                   (#x36 "i32.store") (#x37 "i64.store") (#x38 "f32.store") (#x39 "f64.store")
                                   (#x3A "i32.store8") (#x3B "i32.store16") (#x3C "i64.store8") (#x3D "i64.store16")
                                   (#x3E "i64.store32"))
            do (def opcode name :memarg))
      (def #x3F "memory.size" :u32) (def #x40 "memory.grow" :u32)
      (def #x41 "i32.const" :i32) (def #x42 "i64.const" :i64) (def #x43 "f32.const" :f32) (def #x44 "f64.const" :f64)
      (loop for name in '("i32.eqz" "i32.eq" "i32.ne" "i32.lt_s" "i32.lt_u" "i32.gt_s" "i32.gt_u" "i32.le_s" "i32.le_u"
                          "i32.ge_s" "i32.ge_u" "i64.eqz" "i64.eq" "i64.ne" "i64.lt_s" "i64.lt_u" "i64.gt_s" "i64.gt_u"
                          "i64.le_s" "i64.le_u" "i64.ge_s" "i64.ge_u" "f32.eq" "f32.ne" "f32.lt" "f32.gt" "f32.le" "f32.ge"
                          "f64.eq" "f64.ne" "f64.lt" "f64.gt" "f64.le" "f64.ge" "i32.clz" "i32.ctz" "i32.popcnt" "i32.add"
                          "i32.sub" "i32.mul" "i32.div_s" "i32.div_u" "i32.rem_s" "i32.rem_u" "i32.and" "i32.or" "i32.xor"
                          "i32.shl" "i32.shr_s" "i32.shr_u" "i32.rotl" "i32.rotr" "i64.clz" "i64.ctz" "i64.popcnt" "i64.add"
                          "i64.sub" "i64.mul" "i64.div_s" "i64.div_u" "i64.rem_s" "i64.rem_u" "i64.and" "i64.or" "i64.xor"
                          "i64.shl" "i64.shr_s" "i64.shr_u" "i64.rotl" "i64.rotr" "f32.abs" "f32.neg" "f32.ceil" "f32.floor"
                          "f32.trunc" "f32.nearest" "f32.sqrt" "f32.add" "f32.sub" "f32.mul" "f32.div" "f32.min" "f32.max"
                          "f32.copysign" "f64.abs" "f64.neg" "f64.ceil" "f64.floor" "f64.trunc" "f64.nearest" "f64.sqrt"
                          "f64.add" "f64.sub" "f64.mul" "f64.div" "f64.min" "f64.max" "f64.copysign" "i32.wrap_i64"
                          "i32.trunc_f32_s" "i32.trunc_f32_u" "i32.trunc_f64_s" "i32.trunc_f64_u" "i64.extend_i32_s"
                          "i64.extend_i32_u" "i64.trunc_f32_s" "i64.trunc_f32_u" "i64.trunc_f64_s" "i64.trunc_f64_u"
                          "f32.convert_i32_s" "f32.convert_i32_u" "f32.convert_i64_s" "f32.convert_i64_u" "f32.demote_f64"
                          "f64.convert_i32_s" "f64.convert_i32_u" "f64.convert_i64_s" "f64.convert_i64_u" "f64.promote_f32"
                          "i32.reinterpret_f32" "i64.reinterpret_f64" "f32.reinterpret_i32" "f64.reinterpret_i64"
                          "i32.extend8_s" "i32.extend16_s" "i64.extend8_s" "i64.extend16_s" "i64.extend32_s")
            for opcode from #x45
            do (def opcode name :none))
      (def #xD0 "ref.null" :u32) (def #xD1 "ref.is_null" :none) (def #xD2 "ref.func" :u32))
    table))

;;; 0xFC prefix: subopcode -> (name . immediate count as u32s)
(defparameter *fc-opcode-table*
  '((0 "i32.trunc_sat_f32_s" 0) (1 "i32.trunc_sat_f32_u" 0) (2 "i32.trunc_sat_f64_s" 0) (3 "i32.trunc_sat_f64_u" 0)
    (4 "i64.trunc_sat_f32_s" 0) (5 "i64.trunc_sat_f32_u" 0) (6 "i64.trunc_sat_f64_s" 0) (7 "i64.trunc_sat_f64_u" 0)
    (8 "memory.init" 2) (9 "data.drop" 1) (10 "memory.copy" 2) (11 "memory.fill" 1)
    (12 "table.init" 2) (13 "elem.drop" 1) (14 "table.copy" 2) (15 "table.grow" 1) (16 "table.size" 1) (17 "table.fill" 1)))

(defun blocktype-string (bytes pos)
  "The block type at POS as text; second value the position after it."
  (let ((byte (aref bytes pos)))
    (case byte
      (#x40 (values "" (1+ pos)))
      (#x7F (values "(result i32)" (1+ pos)))
      (#x7E (values "(result i64)" (1+ pos)))
      (#x7D (values "(result f32)" (1+ pos)))
      (#x7C (values "(result f64)" (1+ pos)))
      (#x70 (values "(result funcref)" (1+ pos)))
      (#x69 (values "(result exnref)" (1+ pos)))
      (t (multiple-value-bind (index p) (read-sleb128 bytes pos)
           (values (format nil "(type ~D)" index) p))))))

(defun decode-instruction (bytes pos)
  "The instruction at POS as a string; second value the position after it."
  (let* ((opcode (aref bytes pos))
         (entry (aref *opcode-table* opcode))
         (pos (1+ pos)))
    (cond
      ((= opcode #xFC)
       (multiple-value-bind (sub p) (read-uleb128 bytes pos)
         (let ((entry (assoc sub *fc-opcode-table*)))
           (if entry
               (let ((operands '()))
                 (dotimes (i (third entry))
                   (multiple-value-bind (v q) (read-uleb128 bytes p)
                     (push v operands) (setf p q)))
                 (values (format nil "~A~{ ~D~}" (second entry) (nreverse operands)) p))
               (values (format nil "0xFC ~D" sub) p)))))
      ((null entry) (values (format nil "0x~2,'0X" opcode) pos))
      (t
       (let ((name (car entry)))
         (ecase (cdr entry)
           (:none (values name pos))
           (:blocktype (multiple-value-bind (text p) (blocktype-string bytes pos)
                         (values (if (string= text "") name (format nil "~A ~A" name text)) p)))
           (:u32 (multiple-value-bind (v p) (read-uleb128 bytes pos)
                   (values (format nil "~A ~D" name v) p)))
           (:u32x2 (multiple-value-bind (a p) (read-uleb128 bytes pos)
                     (multiple-value-bind (b q) (read-uleb128 bytes p)
                       (values (if (zerop b) (format nil "~A (type ~D)" name a) (format nil "~A (type ~D) (table ~D)" name a b))
                               q))))
           (:memarg (multiple-value-bind (align p) (read-uleb128 bytes pos)
                      (multiple-value-bind (offset q) (read-uleb128 bytes p)
                        (values (format nil "~A~:[ offset=~D~;~*~]~:[ align=~D~;~*~]" name
                                        (zerop offset) offset (= align (memarg-natural-align name)) (ash 1 align))
                                q))))
           (:i32 (multiple-value-bind (v p) (read-sleb128 bytes pos)
                   (values (format nil "~A ~D~@[ (#x~X)~]" name v (and (> (abs v) 9) (logand v #xffffffff))) p)))
           (:i64 (multiple-value-bind (v p) (read-sleb128 bytes pos)
                   (values (format nil "~A ~D" name v) p)))
           (:f32 (values (format nil "~A ~A" name
                                 (sb-kernel:make-single-float
                                  (let ((bits (logior (aref bytes pos) (ash (aref bytes (+ pos 1)) 8)
                                                      (ash (aref bytes (+ pos 2)) 16) (ash (aref bytes (+ pos 3)) 24))))
                                    (if (logtest bits #x80000000) (- bits #x100000000) bits))))
                         (+ pos 4)))
           (:f64 (values (format nil "~A ~A" name
                                 (let ((lo (logior (aref bytes pos) (ash (aref bytes (+ pos 1)) 8)
                                                   (ash (aref bytes (+ pos 2)) 16) (ash (aref bytes (+ pos 3)) 24)))
                                       (hi (logior (aref bytes (+ pos 4)) (ash (aref bytes (+ pos 5)) 8)
                                                   (ash (aref bytes (+ pos 6)) 16) (ash (aref bytes (+ pos 7)) 24))))
                                   (sb-kernel:make-double-float (if (logtest hi #x80000000) (- hi #x100000000) hi) lo)))
                         (+ pos 8)))
           (:br-table (multiple-value-bind (n p) (read-uleb128 bytes pos)
                        (let ((depths '()))
                          (dotimes (i (1+ n))
                            (multiple-value-bind (d q) (read-uleb128 bytes p)
                              (push d depths) (setf p q)))
                          (values (format nil "~A~{ ~D~}" name (nreverse depths)) p))))
           (:select-t (multiple-value-bind (n p) (read-uleb128 bytes pos)
                        (values name (+ p n))))
           (:try-table (multiple-value-bind (text p) (blocktype-string bytes pos)
                         (multiple-value-bind (n q) (read-uleb128 bytes p)
                           (let ((catches '()))
                             (dotimes (i n)
                               (let ((kind (aref bytes q)))
                                 (incf q)
                                 (multiple-value-bind (tag q2) (if (< kind 2) (read-uleb128 bytes q) (values nil q))
                                   (multiple-value-bind (label q3) (read-uleb128 bytes q2)
                                     (push (format nil "(~A~@[ ~D~] ~D)"
                                                   (ecase kind (0 "catch") (1 "catch_ref") (2 "catch_all") (3 "catch_all_ref"))
                                                   tag label)
                                           catches)
                                     (setf q q3)))))
                             (values (format nil "~A~@[ ~A~]~{ ~A~}" name (if (string= text "") nil text) (nreverse catches))
                                     q)))))))))))

(defun memarg-natural-align (name)
  (cond ((search "8" name) 0)
        ((search "16" name) 1)
        ((search "32" name) (if (or (search "i32" name) (search "f32" name)) 2 2))
        (t (if (or (search "i64" name) (search "f64" name)) 3 2))))

(defun print-function-body (info index stream)
  "Print the body of the function at table INDEX of INFO."
  (let* ((bytes (wmi-bytes info))
         (local (- index (wmi-table-base info)))
         (function (let ((table (wmi-table-functions info)))
                     (if (and table (< local (length table)))
                         (aref table local)
                         (+ local (wmi-n-imported-functions info)))))
         (body (aref (wmi-bodies info) (- function (wmi-n-imported-functions info))))
         (start (car body))
         (end (cdr body))
         (name (gethash function (wmi-names info)))
         (depth 0))
    (format stream "~&; table index ~D, function ~D of ~A~@[ (~A)~], body at #x~X..#x~X (~D bytes)~%"
            index function
            (if (eq info *core-module-info*) "the core module" (format nil "the run-time module at ~D" (wmi-table-base info)))
            name start end (- end start))
    ;; locals
    (multiple-value-bind (n pos) (read-uleb128 bytes start)
      (let ((locals '()))
        (dotimes (i n)
          (multiple-value-bind (count p) (read-uleb128 bytes pos)
            (push (format nil "~D ~A" count
                          (case (aref bytes p) (#x7F "i32") (#x7E "i64") (#x7D "f32") (#x7C "f64") (t "?")))
                  locals)
            (setf pos (1+ p))))
        (when locals (format stream "; locals:~{ ~A~}~%" (nreverse locals))))
      (loop while (< pos end)
            do (let ((at pos))
                 (multiple-value-bind (text next) (decode-instruction bytes pos)
                   (when (or (string= text "end") (string= text "else")) (decf depth))
                   (format stream "; ~5X ~6X  ~v@T~A~%" (- at start) at (* 2 (max depth 0)) text)
                   (when (or (string-equal text "block" :end1 (min 5 (length text)))
                             (string-equal text "loop" :end1 (min 4 (length text)))
                             (string-equal text "if" :end1 (min 2 (length text)))
                             (string-equal text "else" :end1 (min 4 (length text)))
                             (string-equal text "try_table" :end1 (min 9 (length text))))
                     (incf depth))
                   (setf pos next)))))))

(defun disassemble-function (fun &optional (stream *standard-output*))
  "DISASSEMBLE for this target: the Wasm instructions of FUN's function."
  (let* ((index (simple-fun-table-index fun))
         (info (module-info-for-table-index index)))
    (print-function-body info index stream)
    nil))

(defun disassemble-table-index (index &optional (stream *standard-output*))
  "The Wasm instructions of the function at table INDEX (of the core
module or a module loaded at run time)."
  (print-function-body (module-info-for-table-index index) index stream)
  nil)
