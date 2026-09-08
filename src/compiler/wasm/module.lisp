;;;; A WebAssembly module writer.
;;;;
;;;; Builds the binary encoding of a module from functions, imports,
;;;; tables, memories, globals, tags, element and data segments. Written
;;;; in portable Common Lisp because it runs in the cross-compiler on any
;;;; host (genesis emits the cold core's module) and in the target (COMPILE
;;;; emits a module per code component).

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-WASM-ASM")

(deftype octet-vector () '(simple-array (unsigned-byte 8) (*)))

(defstruct (wasm-module (:constructor make-wasm-module ())
                        (:copier nil))
  ;; each type is (params . results), lists of value-type keywords
  (types (make-array 8 :adjustable t :fill-pointer 0))
  ;; (module-name name kind . description); kinds :func :table :memory :global :tag
  (imports (make-array 8 :adjustable t :fill-pointer 0))
  ;; defined functions: (type-index locals body name)
  ;; where LOCALS is a list of (count . valtype) and BODY the
  ;; instruction bytes including the final END
  (functions (make-array 8 :adjustable t :fill-pointer 0))
  ;; (reftype min max-or-nil)
  (tables (make-array 1 :adjustable t :fill-pointer 0))
  ;; (min max-or-nil)
  (memories (make-array 1 :adjustable t :fill-pointer 0))
  ;; (valtype mutable-p init-instruction-bytes)
  (globals (make-array 4 :adjustable t :fill-pointer 0))
  ;; (type-index)
  (tags (make-array 1 :adjustable t :fill-pointer 0))
  ;; (name kind index)
  (exports (make-array 8 :adjustable t :fill-pointer 0))
  (start nil)
  ;; active element segments: (table-index offset-instruction-bytes function-indices)
  (elements (make-array 1 :adjustable t :fill-pointer 0))
  ;; custom sections: (name . octets), newest first
  (custom-sections '())
  ;; (offset-instruction-bytes-or-nil octets): NIL offset means passive
  (datas (make-array 1 :adjustable t :fill-pointer 0)))

;;; Import indices precede defined indices in each index space.
(defun wasm-import-count (module kind)
  (count kind (wasm-module-imports module) :key #'third))

;;;; byte buffers

(defun make-octet-buffer ()
  (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))

(defun buffer-byte (buffer byte)
  (vector-push-extend byte buffer))

(defun buffer-uleb128 (buffer value)
  (declare (type (integer 0) value))
  (loop
    (let ((byte (logand value #x7F)))
      (setf value (ash value -7))
      (cond ((zerop value) (buffer-byte buffer byte) (return))
            (t (buffer-byte buffer (logior byte #x80)))))))

(defun buffer-sleb128 (buffer value)
  (declare (type integer value))
  (loop
    (let ((byte (logand value #x7F)))
      (setf value (ash value -7))
      (cond ((or (and (zerop value) (not (logtest byte #x40)))
                 (and (= value -1) (logtest byte #x40)))
             (buffer-byte buffer byte)
             (return))
            (t (buffer-byte buffer (logior byte #x80)))))))

(defun buffer-octets (buffer octets)
  (loop for b across octets do (buffer-byte buffer b)))

;;; UTF-8, done by hand so that it works on any host Lisp.
(defun buffer-name (buffer string)
  (let ((octets (make-octet-buffer)))
    (loop for char across string
          for code = (char-code char)
          do (cond ((< code #x80) (buffer-byte octets code))
                   ((< code #x800)
                    (buffer-byte octets (logior #xC0 (ash code -6)))
                    (buffer-byte octets (logior #x80 (logand code #x3F))))
                   ((< code #x10000)
                    (buffer-byte octets (logior #xE0 (ash code -12)))
                    (buffer-byte octets (logior #x80 (logand (ash code -6) #x3F)))
                    (buffer-byte octets (logior #x80 (logand code #x3F))))
                   (t
                    (buffer-byte octets (logior #xF0 (ash code -18)))
                    (buffer-byte octets (logior #x80 (logand (ash code -12) #x3F)))
                    (buffer-byte octets (logior #x80 (logand (ash code -6) #x3F)))
                    (buffer-byte octets (logior #x80 (logand code #x3F))))))
    (buffer-uleb128 buffer (length octets))
    (buffer-octets buffer octets)))

(defun buffer-valtype (buffer type)
  (buffer-byte buffer (valtype-code type)))

(defun buffer-limits (buffer min max)
  (cond (max (buffer-byte buffer 1) (buffer-uleb128 buffer min) (buffer-uleb128 buffer max))
        (t (buffer-byte buffer 0) (buffer-uleb128 buffer min))))

;;;; building a module

;;; Return the index of the function type (PARAMS -> RESULTS), adding it
;;; if it is new. Types are deduplicated so that call_indirect signatures
;;; compare equal across modules.
(defun wasm-type-index (module params results)
  (let ((types (wasm-module-types module)))
    (or (position-if (lambda (type)
                       (and (equal (car type) params) (equal (cdr type) results)))
                     types)
        (progn (vector-push-extend (cons params results) types)
               (1- (length types))))))

(defun %add-import (module module-name name kind description)
  (vector-push-extend (list* module-name name kind description)
                      (wasm-module-imports module))
  (1- (wasm-import-count module kind)))

(defun wasm-import-function (module module-name name params results)
  "Import a function; returns its function index."
  (unless (zerop (length (wasm-module-functions module)))
    (error "imports must be declared before defined functions"))
  (%add-import module module-name name :func
               (wasm-type-index module params results)))

(defun wasm-import-table (module module-name name reftype min &optional max)
  (%add-import module module-name name :table (list reftype min max)))

(defun wasm-import-memory (module module-name name min &optional max)
  (%add-import module module-name name :memory (list min max)))

(defun wasm-import-global (module module-name name valtype mutable-p)
  (%add-import module module-name name :global (list valtype mutable-p)))

(defun wasm-import-tag (module module-name name params)
  (%add-import module module-name name :tag (wasm-type-index module params nil)))

(defun wasm-add-function (module params results locals body &key name export)
  "Define a function. LOCALS is a list of (count . valtype). BODY is an
octet vector of instructions ending with END. Returns the function index."
  (let ((index (+ (wasm-import-count module :func)
                  (length (wasm-module-functions module)))))
    (vector-push-extend (list (wasm-type-index module params results) locals body name)
                        (wasm-module-functions module))
    (when export (wasm-add-export module export :func index))
    index))

(defun wasm-add-table (module reftype min &key max export)
  (let ((index (+ (wasm-import-count module :table) (length (wasm-module-tables module)))))
    (vector-push-extend (list reftype min max) (wasm-module-tables module))
    (when export (wasm-add-export module export :table index))
    index))

(defun wasm-add-memory (module min &key max export)
  (let ((index (+ (wasm-import-count module :memory) (length (wasm-module-memories module)))))
    (vector-push-extend (list min max) (wasm-module-memories module))
    (when export (wasm-add-export module export :memory index))
    index))

;;; INIT is a list of instruction bytes for the initializer expression
;;; (without END); the convenience forms below build the common ones.
(defun wasm-add-global (module valtype mutable-p init &key export)
  (let ((index (+ (wasm-import-count module :global) (length (wasm-module-globals module)))))
    (vector-push-extend (list valtype mutable-p init) (wasm-module-globals module))
    (when export (wasm-add-export module export :global index))
    index))

(defun i32-const-expression (value)
  (let ((b (make-octet-buffer)))
    (buffer-byte b #x41)
    (buffer-sleb128 b value)
    (coerce b '(simple-array (unsigned-byte 8) (*)))))

(defun wasm-add-tag (module params &key export)
  (let ((index (+ (wasm-import-count module :tag) (length (wasm-module-tags module)))))
    (vector-push-extend (list (wasm-type-index module params nil)) (wasm-module-tags module))
    (when export (wasm-add-export module export :tag index))
    index))

(defun wasm-add-export (module name kind index)
  (vector-push-extend (list name kind index) (wasm-module-exports module))
  index)

(defun wasm-set-start (module function-index)
  (setf (wasm-module-start module) function-index))

;;; An active element segment placing FUNCTION-INDICES into TABLE-INDEX
;;; starting at the offset computed by OFFSET, an initializer expression
;;; such as (i32-const-expression n) or a global.get of an imported base.
(defun wasm-add-elements (module table-index offset function-indices)
  (vector-push-extend (list table-index offset function-indices)
                      (wasm-module-elements module)))

(defun global-get-expression (global-index)
  (let ((b (make-octet-buffer)))
    (buffer-byte b #x23)
    (buffer-uleb128 b global-index)
    (coerce b '(simple-array (unsigned-byte 8) (*)))))

(defun wasm-add-custom-section (module name octets)
  "A custom section NAME with OCTETS as its payload, written before the
name section."
  (push (cons name octets) (wasm-module-custom-sections module)))

(defun wasm-add-data (module offset octets)
  "OFFSET is an initializer expression for an active segment in memory 0,
or NIL for a passive segment."
  (vector-push-extend (list offset octets) (wasm-module-datas module)))

;;;; encoding

(defun buffer-section (out id contents)
  (unless (zerop (length contents))
    (buffer-byte out id)
    (buffer-uleb128 out (length contents))
    (buffer-octets out contents)))

(defun buffer-function-type (b type)
  (buffer-byte b #x60)
  (buffer-uleb128 b (length (car type)))
  (dolist (p (car type)) (buffer-valtype b p))
  (buffer-uleb128 b (length (cdr type)))
  (dolist (r (cdr type)) (buffer-valtype b r)))

(defun buffer-table-type (b reftype min max)
  (buffer-valtype b reftype)
  (buffer-limits b min max))

(defun buffer-global-type (b valtype mutable-p)
  (buffer-valtype b valtype)
  (buffer-byte b (if mutable-p 1 0)))

(defun buffer-expression (b bytes)
  (buffer-octets b bytes)
  (buffer-byte b #x0B))

(defun wasm-module-octets (module)
  "Return the binary encoding of MODULE as an octet vector."
  (let ((out (make-octet-buffer))
        (types (wasm-module-types module))
        (imports (wasm-module-imports module))
        (functions (wasm-module-functions module))
        (tables (wasm-module-tables module))
        (memories (wasm-module-memories module))
        (globals (wasm-module-globals module))
        (tags (wasm-module-tags module))
        (exports (wasm-module-exports module))
        (elements (wasm-module-elements module))
        (datas (wasm-module-datas module)))
    ;; magic and version
    (buffer-octets out #(#x00 #x61 #x73 #x6D #x01 #x00 #x00 #x00))
    ;; 1 type
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length types))
      (loop for type across types do (buffer-function-type b type))
      (buffer-section out 1 b))
    ;; 2 import
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length imports))
      (loop for (module-name name kind . desc) across imports
            do (buffer-name b module-name)
               (buffer-name b name)
               (ecase kind
                 (:func (buffer-byte b 0) (buffer-uleb128 b desc))
                 (:table (buffer-byte b 1) (apply #'buffer-table-type b desc))
                 (:memory (buffer-byte b 2) (apply #'buffer-limits b desc))
                 (:global (buffer-byte b 3) (apply #'buffer-global-type b desc))
                 (:tag (buffer-byte b 4) (buffer-byte b 0) (buffer-uleb128 b desc))))
      (buffer-section out 2 b))
    ;; 3 function
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length functions))
      (loop for f across functions do (buffer-uleb128 b (first f)))
      (buffer-section out 3 b))
    ;; 4 table
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length tables))
      (loop for (reftype min max) across tables do (buffer-table-type b reftype min max))
      (buffer-section out 4 b))
    ;; 5 memory
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length memories))
      (loop for (min max) across memories do (buffer-limits b min max))
      (buffer-section out 5 b))
    ;; 13 tag (precedes global in the binary format)
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length tags))
      (loop for (type-index) across tags do (buffer-byte b 0) (buffer-uleb128 b type-index))
      (buffer-section out 13 b))
    ;; 6 global
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length globals))
      (loop for (valtype mutable-p init) across globals
            do (buffer-global-type b valtype mutable-p)
               (buffer-expression b init))
      (buffer-section out 6 b))
    ;; 7 export
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length exports))
      (loop for (name kind index) across exports
            do (buffer-name b name)
               (buffer-byte b (ecase kind (:func 0) (:table 1) (:memory 2) (:global 3) (:tag 4)))
               (buffer-uleb128 b index))
      (buffer-section out 7 b))
    ;; 8 start
    (when (wasm-module-start module)
      (let ((b (make-octet-buffer)))
        (buffer-uleb128 b (wasm-module-start module))
        (buffer-section out 8 b)))
    ;; 9 element
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length elements))
      (loop for (table-index offset function-indices) across elements
            do (buffer-byte b 2)        ; active, explicit table index, funcidx list
               (buffer-uleb128 b table-index)
               (buffer-expression b offset)
               (buffer-byte b 0)        ; elemkind funcref
               (buffer-uleb128 b (length function-indices))
               (dolist (f function-indices) (buffer-uleb128 b f)))
      (buffer-section out 9 b))
    ;; 12 data count (required when bulk-memory instructions reference segments)
    (unless (zerop (length datas))
      (let ((b (make-octet-buffer)))
        (buffer-uleb128 b (length datas))
        (buffer-section out 12 b)))
    ;; 10 code
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length functions))
      (loop for (nil locals body) across functions
            do (let ((f (make-octet-buffer)))
                 (buffer-uleb128 f (length locals))
                 (loop for (count . type) in locals
                       do (buffer-uleb128 f count) (buffer-valtype f type))
                 (buffer-octets f body)
                 (buffer-uleb128 b (length f))
                 (buffer-octets b f)))
      (buffer-section out 10 b))
    ;; 11 data
    (let ((b (make-octet-buffer)))
      (buffer-uleb128 b (length datas))
      (loop for (offset octets) across datas
            do (cond (offset (buffer-byte b 0) (buffer-expression b offset))
                     (t (buffer-byte b 1)))
               (buffer-uleb128 b (length octets))
               (buffer-octets b octets))
      (buffer-section out 11 b))
    ;; 0 custom sections added by WASM-ADD-CUSTOM-SECTION
    (loop for (name . octets) in (reverse (wasm-module-custom-sections module))
          do (let ((b (make-octet-buffer)))
               (buffer-name b name)
               (buffer-octets b octets)
               (buffer-section out 0 b)))
    ;; 0 custom "name": function names, for debugging and profiling
    (let ((named (loop for f across functions
                       for i from (wasm-import-count module :func)
                       when (fourth f) collect (cons i (fourth f)))))
      (when named
        (let ((b (make-octet-buffer)) (sub (make-octet-buffer)))
          (buffer-name b "name")
          (buffer-uleb128 sub (length named))
          (loop for (index . name) in named
                do (buffer-uleb128 sub index) (buffer-name sub name))
          (buffer-byte b 1)             ; function names subsection
          (buffer-uleb128 b (length sub))
          (buffer-octets b sub)
          (buffer-section out 0 b))))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun write-wasm-module (module pathname)
  (with-open-file (stream pathname :direction :output :element-type '(unsigned-byte 8)
                                   :if-exists :supersede :if-does-not-exist :create)
    (write-sequence (wasm-module-octets module) stream))
  pathname)

;;; Assemble the instructions emitted by THUNK into an octet vector,
;;; appending END unless END is NIL. Assembles through a section and
;;; %ASSEMBLE, the same path codegen uses, so that labels, back-patches
;;; and fixup notes all work. Returns the octets and the finalized segment.
(defun assemble-octets (thunk &key (end t))
  (let ((segment (sb-assem:make-segment))
        (section (sb-assem::make-section)))
    (sb-assem:assemble (section)
      (funcall thunk)
      (when end (inst end)))
    (sb-assem::%assemble segment section)
    (values (coerce (sb-assem:segment-contents-as-vector segment)
                    '(simple-array (unsigned-byte 8) (*)))
            segment)))

(defmacro with-wasm-body (() &body body)
  "Assemble BODY's instructions followed by END into an octet vector."
  `(values (assemble-octets (lambda () ,@body))))
