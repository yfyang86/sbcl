;;;; The WebAssembly instruction encoder.
;;;;
;;;; Wasm code is a byte stream of variable-length instructions with
;;;; LEB128 immediates and structured control flow. This file defines
;;;; every instruction the backend emits, plus a small set of
;;;; pseudo-instructions (JUMP, JUMP-IF, JUMP-TABLE, FUNC-BEGIN,
;;;; FUNC-END) that carry assembler labels. The pseudo-instructions emit
;;;; no bytes; they record CONTROL-NOTEs on the segment, and the function
;;;; assembler (func-asm.lisp) rewrites the linear stream into
;;;; block/loop/br form once label positions are final. See
;;;; doc/wasm-port/02-design.md, 2.5.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-WASM-ASM")

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Imports from SB-VM into this package
  (import '(sb-vm::registers sb-vm::float-registers
            sb-vm::tn-byte-offset)))

;;;; Value types and block types

(defconstant +i32+ #x7F)
(defconstant +i64+ #x7E)
(defconstant +f32+ #x7D)
(defconstant +f64+ #x7C)
(defconstant +v128+ #x7B)
(defconstant +funcref+ #x70)
(defconstant +externref+ #x6F)
(defconstant +exnref+ #x69)
(defconstant +empty-block-type+ #x40)

(defun valtype-code (type)
  (ecase type
    (:i32 +i32+) (:i64 +i64+) (:f32 +f32+) (:f64 +f64+) (:v128 +v128+)
    (:funcref +funcref+) (:externref +externref+) (:exnref +exnref+)))

;;;; LEB128 emitters

(defun emit-uleb128 (segment value)
  (declare (type (integer 0) value))
  (loop
    (let ((byte (logand value #x7F)))
      (setf value (ash value -7))
      (cond ((zerop value)
             (emit-byte segment byte)
             (return))
            (t
             (emit-byte segment (logior byte #x80)))))))

(defun emit-sleb128 (segment value)
  (declare (type integer value))
  (loop
    (let ((byte (logand value #x7F)))
      (setf value (ash value -7))
      (cond ((or (and (zerop value) (not (logtest byte #x40)))
                 (and (= value -1) (logtest byte #x40)))
             (emit-byte segment byte)
             (return))
            (t
             (emit-byte segment (logior byte #x80)))))))

;;; A five-byte LEB128 encoding of a 32-bit value. Used for immediates
;;; that are patched after assembly (fixups), which must not change size.
(defun emit-fixed-sleb128-32 (segment value)
  (declare (type (or (signed-byte 32) (unsigned-byte 32)) value))
  (let ((value (logand value #xFFFFFFFF)))
    (dotimes (i 4)
      (emit-byte segment (logior (logand value #x7F) #x80))
      (setf value (ash value -7)))
    ;; last byte: the remaining 4 bits, sign-extended so that the
    ;; encoding is valid for both signed and unsigned readers of an i32
    (emit-byte segment (logand value #x7F))))

(defun emit-ieee-single (segment bits)
  "BITS is the IEEE single-float bit pattern as an (unsigned-byte 32)."
  (declare (type (unsigned-byte 32) bits))
  (dotimes (i 4)
    (emit-byte segment (ldb (byte 8 (* i 8)) bits))))

(defun emit-ieee-double (segment bits)
  "BITS is the IEEE double-float bit pattern as an (unsigned-byte 64)."
  (declare (type (unsigned-byte 64) bits))
  (dotimes (i 8)
    (emit-byte segment (ldb (byte 8 (* i 8)) bits))))

;;;; Data-emitting pseudo-instructions

(define-instruction byte (segment byte)
  (:emitter (emit-byte segment byte)))

;;; a raw little-endian 32-bit word in the constant vector or data
(defun emit-word (segment word)
  (let ((word (logand word #xFFFFFFFF)))
    (dotimes (i 4)
      (emit-byte segment (ldb (byte 8 (* i 8)) word)))))

(define-instruction word (segment word)
  (:emitter
   (etypecase word
     (fixup
      (note-fixup segment :absolute word)
      (emit-word segment 0))
     (integer
      (emit-word segment word)))))

(define-instruction machine-word (segment word)
  (:emitter
   (etypecase word
     (fixup
      (note-fixup segment :absolute word)
      (emit-word segment 0))
     (integer
      (emit-word segment word)))))

;;;; Control instructions

(defun emit-block-type (segment type)
  (cond ((null type) (emit-byte segment +empty-block-type+))
        ((keywordp type) (emit-byte segment (valtype-code type)))
        ;; a type index for multi-value block signatures
        (t (emit-sleb128 segment type))))

(macrolet ((define-simple (name opcode)
             `(define-instruction ,name (segment)
                (:emitter (emit-byte segment ,opcode)))))
  (define-simple unreachable #x00)
  (define-simple nop #x01)
  (define-simple else #x05)
  (define-simple end #x0B)
  (define-simple return #x0F)
  (define-simple throw_ref #x0A)
  (define-simple drop #x1A)
  (define-simple select #x1B))

(define-instruction block (segment &optional type)
  (:emitter (emit-byte segment #x02) (emit-block-type segment type)))
(define-instruction loop (segment &optional type)
  (:emitter (emit-byte segment #x03) (emit-block-type segment type)))
(define-instruction if (segment &optional type)
  (:emitter (emit-byte segment #x04) (emit-block-type segment type)))

;;; br N, br_if N: N is a relative label depth
(define-instruction br (segment depth)
  (:emitter (emit-byte segment #x0C) (emit-uleb128 segment depth)))
(define-instruction br_if (segment depth)
  (:emitter (emit-byte segment #x0D) (emit-uleb128 segment depth)))
(define-instruction br_table (segment depths default)
  (:emitter
   (emit-byte segment #x0E)
   (emit-uleb128 segment (length depths))
   (dolist (d depths) (emit-uleb128 segment d))
   (emit-uleb128 segment default)))

(define-instruction call (segment func)
  (:emitter
   (emit-byte segment #x10)
   (etypecase func
     (fixup (note-fixup segment :leb128 func) (emit-fixed-sleb128-32 segment 0))
     (integer (emit-uleb128 segment func)))))
(define-instruction call_indirect (segment type-index &optional (table 0))
  (:emitter
   (emit-byte segment #x11)
   (emit-uleb128 segment type-index)
   (emit-uleb128 segment table)))
(define-instruction return_call (segment func)
  (:emitter (emit-byte segment #x12) (emit-uleb128 segment func)))
(define-instruction return_call_indirect (segment type-index &optional (table 0))
  (:emitter
   (emit-byte segment #x13)
   (emit-uleb128 segment type-index)
   (emit-uleb128 segment table)))

;;; try_table bt vec(catch): each catch clause is one of
;;;   (:catch tag label-depth) (:catch-ref tag label-depth)
;;;   (:catch-all label-depth) (:catch-all-ref label-depth)
(define-instruction try_table (segment type catches)
  (:emitter
   (emit-byte segment #x1F)
   (emit-block-type segment type)
   (emit-uleb128 segment (length catches))
   (dolist (c catches)
     (ecase (first c)
       (:catch (emit-byte segment #x00)
        (emit-uleb128 segment (second c)) (emit-uleb128 segment (third c)))
       (:catch-ref (emit-byte segment #x01)
        (emit-uleb128 segment (second c)) (emit-uleb128 segment (third c)))
       (:catch-all (emit-byte segment #x02) (emit-uleb128 segment (second c)))
       (:catch-all-ref (emit-byte segment #x03) (emit-uleb128 segment (second c)))))))
(define-instruction throw (segment tag)
  (:emitter (emit-byte segment #x08) (emit-uleb128 segment tag)))

;;;; Reference instructions

(define-instruction ref.null (segment heap-type)
  (:emitter (emit-byte segment #xD0) (emit-byte segment (valtype-code heap-type))))
(define-instruction ref.is_null (segment)
  (:emitter (emit-byte segment #xD1)))
(define-instruction ref.func (segment func)
  (:emitter (emit-byte segment #xD2) (emit-uleb128 segment func)))

;;;; Variable instructions

(macrolet ((define-var (name opcode)
             `(define-instruction ,name (segment index)
                (:emitter (emit-byte segment ,opcode) (emit-uleb128 segment index)))))
  (define-var local.get #x20)
  (define-var local.set #x21)
  (define-var local.tee #x22)
  (define-var global.get #x23)
  (define-var global.set #x24)
  (define-var table.get #x25)
  (define-var table.set #x26))

(macrolet ((define-fc-table (name sub)
             `(define-instruction ,name (segment &optional (table 0))
                (:emitter (emit-byte segment #xFC) (emit-uleb128 segment ,sub)
                          (emit-uleb128 segment table)))))
  (define-fc-table table.grow 15)
  (define-fc-table table.size 16)
  (define-fc-table table.fill 17))

;;;; Memory instructions
;;;
;;; The memarg is (align-exponent offset). Natural alignment is the
;;; default; a VOP passes an explicit :offset for addressing modes.

(macrolet ((define-mem (name opcode natural-align)
             `(define-instruction ,name (segment &optional (offset 0) (align ,natural-align))
                (:emitter
                 (emit-byte segment ,opcode)
                 (emit-uleb128 segment align)
                 (emit-uleb128 segment offset)))))
  (define-mem i32.load #x28 2)
  (define-mem i64.load #x29 3)
  (define-mem f32.load #x2A 2)
  (define-mem f64.load #x2B 3)
  (define-mem i32.load8_s #x2C 0)
  (define-mem i32.load8_u #x2D 0)
  (define-mem i32.load16_s #x2E 1)
  (define-mem i32.load16_u #x2F 1)
  (define-mem i64.load8_s #x30 0)
  (define-mem i64.load8_u #x31 0)
  (define-mem i64.load16_s #x32 1)
  (define-mem i64.load16_u #x33 1)
  (define-mem i64.load32_s #x34 2)
  (define-mem i64.load32_u #x35 2)
  (define-mem i32.store #x36 2)
  (define-mem i64.store #x37 3)
  (define-mem f32.store #x38 2)
  (define-mem f64.store #x39 3)
  (define-mem i32.store8 #x3A 0)
  (define-mem i32.store16 #x3B 1)
  (define-mem i64.store8 #x3C 0)
  (define-mem i64.store16 #x3D 1)
  (define-mem i64.store32 #x3E 2))

(define-instruction memory.size (segment)
  (:emitter (emit-byte segment #x3F) (emit-byte segment 0)))
(define-instruction memory.grow (segment)
  (:emitter (emit-byte segment #x40) (emit-byte segment 0)))
(define-instruction memory.copy (segment)
  (:emitter (emit-byte segment #xFC) (emit-uleb128 segment 10)
            (emit-byte segment 0) (emit-byte segment 0)))
(define-instruction memory.fill (segment)
  (:emitter (emit-byte segment #xFC) (emit-uleb128 segment 11) (emit-byte segment 0)))

;;;; Numeric instructions

;;; i32.const accepts a fixup, in which case a fixed five-byte immediate
;;; is emitted and patched at load time.
(define-instruction i32.const (segment value)
  (:emitter
   (emit-byte segment #x41)
   (etypecase value
     (fixup
      (note-fixup segment :leb128 value)
      (emit-fixed-sleb128-32 segment 0))
     ((signed-byte 32) (emit-sleb128 segment value))
     ((unsigned-byte 32) (emit-sleb128 segment (- value (ash 1 32)))))))

(define-instruction i64.const (segment value)
  (:emitter
   (emit-byte segment #x42)
   (etypecase value
     ((signed-byte 64) (emit-sleb128 segment value))
     ((unsigned-byte 64) (emit-sleb128 segment (- value (ash 1 64)))))))

;;; The float constants take the IEEE bit pattern, not a float, so that
;;; the cross-compiler (whose floats are not the host's) can emit them.
(define-instruction f32.const (segment bits)
  (:emitter (emit-byte segment #x43) (emit-ieee-single segment bits)))
(define-instruction f64.const (segment bits)
  (:emitter (emit-byte segment #x44) (emit-ieee-double segment bits)))

(macrolet ((define-numeric (&rest specs)
             `(progn
                ,@(loop for (name opcode) in specs
                        collect `(define-instruction ,name (segment)
                                   (:emitter (emit-byte segment ,opcode)))))))
  (define-numeric
    ;; i32 comparisons
    (i32.eqz #x45) (i32.eq #x46) (i32.ne #x47)
    (i32.lt_s #x48) (i32.lt_u #x49) (i32.gt_s #x4A) (i32.gt_u #x4B)
    (i32.le_s #x4C) (i32.le_u #x4D) (i32.ge_s #x4E) (i32.ge_u #x4F)
    ;; i64 comparisons
    (i64.eqz #x50) (i64.eq #x51) (i64.ne #x52)
    (i64.lt_s #x53) (i64.lt_u #x54) (i64.gt_s #x55) (i64.gt_u #x56)
    (i64.le_s #x57) (i64.le_u #x58) (i64.ge_s #x59) (i64.ge_u #x5A)
    ;; float comparisons
    (f32.eq #x5B) (f32.ne #x5C) (f32.lt #x5D) (f32.gt #x5E) (f32.le #x5F) (f32.ge #x60)
    (f64.eq #x61) (f64.ne #x62) (f64.lt #x63) (f64.gt #x64) (f64.le #x65) (f64.ge #x66)
    ;; i32 arithmetic
    (i32.clz #x67) (i32.ctz #x68) (i32.popcnt #x69)
    (i32.add #x6A) (i32.sub #x6B) (i32.mul #x6C)
    (i32.div_s #x6D) (i32.div_u #x6E) (i32.rem_s #x6F) (i32.rem_u #x70)
    (i32.and #x71) (i32.or #x72) (i32.xor #x73)
    (i32.shl #x74) (i32.shr_s #x75) (i32.shr_u #x76) (i32.rotl #x77) (i32.rotr #x78)
    ;; i64 arithmetic
    (i64.clz #x79) (i64.ctz #x7A) (i64.popcnt #x7B)
    (i64.add #x7C) (i64.sub #x7D) (i64.mul #x7E)
    (i64.div_s #x7F) (i64.div_u #x80) (i64.rem_s #x81) (i64.rem_u #x82)
    (i64.and #x83) (i64.or #x84) (i64.xor #x85)
    (i64.shl #x86) (i64.shr_s #x87) (i64.shr_u #x88) (i64.rotl #x89) (i64.rotr #x8A)
    ;; f32 arithmetic
    (f32.abs #x8B) (f32.neg #x8C) (f32.ceil #x8D) (f32.floor #x8E) (f32.trunc #x8F)
    (f32.nearest #x90) (f32.sqrt #x91) (f32.add #x92) (f32.sub #x93) (f32.mul #x94)
    (f32.div #x95) (f32.min #x96) (f32.max #x97) (f32.copysign #x98)
    ;; f64 arithmetic
    (f64.abs #x99) (f64.neg #x9A) (f64.ceil #x9B) (f64.floor #x9C) (f64.trunc #x9D)
    (f64.nearest #x9E) (f64.sqrt #x9F) (f64.add #xA0) (f64.sub #xA1) (f64.mul #xA2)
    (f64.div #xA3) (f64.min #xA4) (f64.max #xA5) (f64.copysign #xA6)
    ;; conversions
    (i32.wrap_i64 #xA7)
    (i32.trunc_f32_s #xA8) (i32.trunc_f32_u #xA9) (i32.trunc_f64_s #xAA) (i32.trunc_f64_u #xAB)
    (i64.extend_i32_s #xAC) (i64.extend_i32_u #xAD)
    (i64.trunc_f32_s #xAE) (i64.trunc_f32_u #xAF) (i64.trunc_f64_s #xB0) (i64.trunc_f64_u #xB1)
    (f32.convert_i32_s #xB2) (f32.convert_i32_u #xB3) (f32.convert_i64_s #xB4) (f32.convert_i64_u #xB5)
    (f32.demote_f64 #xB6)
    (f64.convert_i32_s #xB7) (f64.convert_i32_u #xB8) (f64.convert_i64_s #xB9) (f64.convert_i64_u #xBA)
    (f64.promote_f32 #xBB)
    (i32.reinterpret_f32 #xBC) (i64.reinterpret_f64 #xBD)
    (f32.reinterpret_i32 #xBE) (f64.reinterpret_i64 #xBF)
    ;; sign extension
    (i32.extend8_s #xC0) (i32.extend16_s #xC1)
    (i64.extend8_s #xC2) (i64.extend16_s #xC3) (i64.extend32_s #xC4)))

;;; saturating truncations (0xFC prefix)
(macrolet ((define-sat (&rest specs)
             `(progn
                ,@(loop for (name sub) in specs
                        collect `(define-instruction ,name (segment)
                                   (:emitter (emit-byte segment #xFC)
                                             (emit-uleb128 segment ,sub)))))))
  (define-sat
    (i32.trunc_sat_f32_s 0) (i32.trunc_sat_f32_u 1)
    (i32.trunc_sat_f64_s 2) (i32.trunc_sat_f64_u 3)
    (i64.trunc_sat_f32_s 4) (i64.trunc_sat_f32_u 5)
    (i64.trunc_sat_f64_s 6) (i64.trunc_sat_f64_u 7)))

;;;; Control-flow pseudo-instructions
;;;;
;;;; These take assembler labels, as branch instructions do on every other
;;;; backend, and emit nothing. Each records a CONTROL-NOTE with its final
;;;; position on the segment's BACKEND-DATA. The notes are recorded when
;;;; the segment is finalized (they are zero-size back-patches), so their
;;;; positions are the final ones, comparable with LABEL-POSITION.

(defstruct (control-note (:constructor make-control-note (kind posn labels data))
                         (:copier nil))
  ;; :jump :jump-if :jump-table :func-begin :func-end
  (kind nil :type symbol :read-only t)
  ;; byte position in the finalized segment
  (posn 0 :type index :read-only t)
  ;; the label, or for :jump-table the list of labels
  (labels nil :read-only t)
  ;; :jump-table default label; :func-begin plist (:params :results :locals)
  (data nil :read-only t))

(defun note-control (segment kind labels data)
  (dolist (label (if (listp labels) labels (list labels)))
    (when label (setf (sb-assem::label-usedp label) t)))
  (emit-back-patch
   segment 0
   (lambda (segment posn)
     (push (make-control-note kind posn labels data)
           (sb-assem::segment-backend-data segment)))))

;;; Return the control notes of a finalized SEGMENT in emission order,
;;; which is also position order (several notes may share a position).
(defun segment-control-notes (segment)
  (reverse (sb-assem::segment-backend-data segment)))

;;; unconditional branch to LABEL
(define-instruction jump (segment label)
  (:emitter (note-control segment :jump label nil)))

;;; pops an i32; branches to LABEL if it is nonzero
(define-instruction jump-if (segment label)
  (:emitter (note-control segment :jump-if label nil)))

;;; pops an i32 index; branches to the indexed label, or DEFAULT
(define-instruction jump-table (segment labels default)
  (:emitter (note-control segment :jump-table labels default)))

;;; marks the start of a Wasm function whose entry is LABEL. PARAMS and
;;; RESULTS are lists of value-type keywords; LOCALS is a list of
;;; (count . type) groups declared in addition to the dispatcher's own.
(define-instruction func-begin (segment label &key params results locals)
  (:emitter (note-control segment :func-begin label
                          (list :params params :results results :locals locals))))

(define-instruction func-end (segment)
  (:emitter (note-control segment :func-end nil nil)))

;;;; Fixups
;;;;
;;;; Fixups are applied to a module's bytes before it is instantiated, not
;;;; to a code object in the heap (Sprint 4).

(defun sb-vm:fixup-code-object (code offset value kind flavor)
  (declare (ignore code offset value kind flavor))
  (error "FIXUP-CODE-OBJECT is not implemented on this target yet"))
