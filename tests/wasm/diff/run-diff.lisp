;;;; Level-1 differential tests: compile Lisp functions with the wasm
;;;; cross-compiler, write each as a module, and record the expected result
;;;; of applying the same function in the host Lisp, as a raw target word.
;;;;
;;;; Runs inside obj/xbuild/wasm/xc.core. The cases come from
;;;; tests/wasm/diff/cases.lisp: a list of (name lambda-list body args...)
;;;; where each ARGS is a list of Lisp values. Only fixnums, characters,
;;;; T and NIL are representable as raw words without a heap.
;;;;
;;;; (sb-wasm-asm::run-diff "tests/wasm/diff/cases.lisp" "out-dir")

(in-package "SB-WASM-ASM")

(defvar *diff-functions* (make-hash-table :test 'equal))

;;; The linkage cells of the mini-runtime (tests/wasm/minirt.c, reset):
;;; the C shadow-stack helpers the catch and unwind blocks call.
(defparameter *minirt-cells* '(("c_stack_save" . #x100) ("c_stack_restore" . #x104)))

(defun target-word (value)
  "The raw 32-bit register word representing VALUE on the target."
  (typecase value
    ((signed-byte #.sb-vm:n-fixnum-bits)
     (logand (ash value sb-vm:n-fixnum-tag-bits) #xFFFFFFFF))
    (integer (error "~D is not a fixnum on the target" value))
    (character (logior (ash (char-code value) sb-vm:n-widetag-bits) sb-vm:character-widetag))
    (null sb-vm:nil-value)
    ((eql t) (+ sb-vm:nil-value (sb-vm:static-symbol-offset t)))
    (t (error "no raw word for ~S" value))))

;;; The cases are read in a target package, where DOUBLE-FLOAT, TRUNCATE
;;; and the like are the SB-XC shadows the cross-compiler defines; the
;;; host's COMPILE wants the CL symbols.
(defun host-form (form)
  (let ((sb-xc (find-package "SB-XC"))
        ;; the host's SYMBOL-PACKAGE (this package sees XC-STRICT-CL)
        (symbol-package (find-symbol "SYMBOL-PACKAGE" "COMMON-LISP"))
        (package-name (find-symbol "PACKAGE-NAME" "COMMON-LISP")))
    (labels ((host-symbol (x)
               (let ((package (funcall symbol-package x)))
                 (cond ((null package) x)
                       ((eq package sb-xc)
                        (or (find-symbol (symbol-name x) "COMMON-LISP") x))
                       (t
                        ;; SB-KERNEL:DOUBLE-FLOAT-HIGH-BITS and the like:
                        ;; the host's own version lives in HOST-SB-KERNEL
                        (let ((host (find-package
                                     (concatenate 'string "HOST-" (funcall package-name package)))))
                          (or (and host (find-symbol (symbol-name x) host)) x))))))
             (walk (x)
               (cond ((consp x) (cons (walk (car x)) (walk (cdr x))))
                     ((symbolp x) (host-symbol x))
                     (t x))))
      (walk form))))

(defun host-eval (lambda-list body args)
  "Apply the case's function in the host, with the target's fixnum range."
  (let ((fn (compile nil (host-form `(lambda ,lambda-list ,@body)))))
    (apply fn args)))

;;; The cross-compiler needs the same dynamic state make-host-2 gives it
;;; (src/cold/compile-cold-sbcl.lisp, IN-TARGET-CROSS-COMPILATION-MODE).
(defun call-in-target-mode (fun)
  (let ((sb-ext:*derive-function-types* t)
        (sb-xc:*features* (cons :sb-xc sb-xc:*features*))
        (*readtable* sb-cold:*xc-readtable*))
    (sb-c::init-xc-policy '())
    (sb-xc:proclaim '(optimize (compilation-speed 1) (debug 1)
                      (sb-ext:inhibit-warnings 2)
                      (safety 2) (space 1) (speed 2)
                      (sb-c:insert-step-conditions 0)
                      (sb-c:alien-funcall-saves-fp-and-pc 0)
                      (sb-c:store-coverage-data 0)))
    (funcall fun)))

;;; The cases are read in a target package. COMMON-LISP-USER in the
;;; cross-compiler image is the host's, whose NUMBERP is not the
;;; SB-XC:NUMBERP the compiler knows as a type predicate.
(defun case-package-name () "SB-IMPL")

;;; The function name of a case: prefixed, so that a case named after a
;;; CL function (numberp, max) does not redefine that function while the
;;; compiler is using it.
(defun case-function-name (name)
  (format nil "WASM-CASE-~:@(~A~)" name))

;;; Every entry of the component maps to (position functions asm-routines
;;; unimplemented): the module holds all the component's functions, the
;;; case calls the entry at POSITION.
(defun component-hook (ir2-component functions asm-routines unimplemented)
  (declare (ignore ir2-component))
  (dolist (function functions)
    (let ((entry (wasm-function-entry function)))
      (when entry
        (setf (gethash (string (sb-c::entry-info-name entry)) *diff-functions*)
              (list (wasm-function-index function) functions asm-routines unimplemented))))))

(defun run-diff (cases-file out-dir)
  (ensure-directories-exist (format nil "~A/" out-dir))
  (let* ((cases (with-open-file (s cases-file)
                  (let ((*package* (find-package (case-package-name)))) (read s))))
         (source (format nil "~A/cases-source.lisp" out-dir))
         (fasl (format nil "~A/cases.fasl" out-dir))
         (case-lines '())
         (n-modules 0))
    ;; one source file with a DEFUN per case
    (with-open-file (s source :direction :output :if-exists :supersede)
      (let ((*package* (find-package (case-package-name))))
        (format s "(in-package ~S)~%" (case-package-name))
        (dolist (c cases)
          (destructuring-bind (name lambda-list body &rest args) c
            (declare (ignore args))
            (format s "~S~%" `(defun ,(intern (case-function-name name) (case-package-name))
                                  ,lambda-list ,@body))))))
    ;; cross-compile it, collecting the lowered functions
    (clrhash *diff-functions*)
    (let ((*wasm-component-hook* #'component-hook))
      (call-in-target-mode (lambda () (sb-xc:compile-file source :output-file fasl))))
    ;; the assembly routines, as a module exporting them
    (let ((*wasm-assembly-hook*
            (lambda (functions asm-routines)
              (let ((m (make-lisp-module :asm-routines asm-routines)))
                (add-lisp-functions m functions :export t :foreign-cells *minirt-cells*)
                (write-wasm-module m (format nil "~A/asm.wasm" out-dir))))))
      (call-in-target-mode
       (lambda ()
         (sb-c::assemble-file "src/assembly/wasm/assem-rtns.lisp"
                              :output-file (format nil "~A/assem-rtns.assem-obj" out-dir)))))
    ;; one module per case
    (dolist (c cases)
      (destructuring-bind (name lambda-list body &rest arg-lists) c
        (let ((found (gethash (case-function-name name) *diff-functions*)))
          (cond ((not found)
                 (push (format nil "# ~A: not compiled" name) case-lines))
                ((fourth found)
                 (push (format nil "# ~A: unimplemented VOPs ~{~A~^ ~}" name (fourth found))
                       case-lines))
                (t
                 (destructuring-bind (position functions asm-routines unimplemented) found
                   (declare (ignore unimplemented))
                   (let ((m (make-lisp-module :asm-routines asm-routines))
                         (file (format nil "~A.wasm" (string-downcase name))))
                     (add-lisp-functions m functions :foreign-cells *minirt-cells*)
                     (write-wasm-module m (format nil "~A/~A" out-dir file))
                     (incf n-modules)
                     (dolist (args arg-lists)
                       (let ((expected (host-eval lambda-list body args)))
                         (push (format nil "~A ~D ~{~D ~}=> ~D ~A"
                                       file position (mapcar #'target-word args)
                                       (target-word expected) name)
                               case-lines))))))))))
    (with-open-file (s (format nil "~A/cases.txt" out-dir) :direction :output :if-exists :supersede)
      ;; the static symbols exist only as headers, enough for SYMBOLP
      (format s "# static symbol headers (address value), stored before each case~%")
      (loop for symbol across sb-vm::+static-symbols+ do
        (format s "!poke ~D ~D~%"
                (- (sb-vm::static-symbol-address symbol) sb-vm:other-pointer-lowtag)
                (sb-vm::compute-object-header sb-vm:symbol-size sb-vm:symbol-widetag)))
      (dolist (line (reverse case-lines)) (write-line line s)))
    (format t "~&diff: ~D modules written, ~D case lines~%" n-modules (length case-lines))
    (funcall (intern "EXIT" "HOST-SB-EXT") :code 0)))
