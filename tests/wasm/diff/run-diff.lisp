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

(defun host-eval (lambda-list body args)
  "Apply the case's function in the host, with the target's fixnum range."
  (let ((fn (compile nil `(lambda ,lambda-list ,@body))))
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

(defun component-hook (ir2-component functions unimplemented)
  (declare (ignore ir2-component))
  (dolist (entry functions)
    (destructuring-bind (entry-info body locals) entry
      (let ((name (sb-c::entry-info-name entry-info)))
        (setf (gethash (string name) *diff-functions*)
              (list body locals unimplemented))))))

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
    ;; one module per case
    (dolist (c cases)
      (destructuring-bind (name lambda-list body &rest arg-lists) c
        (let ((found (gethash (case-function-name name) *diff-functions*)))
          (cond ((not found)
                 (push (format nil "# ~A: not compiled" name) case-lines))
                ((third found)
                 (push (format nil "# ~A: unimplemented VOPs ~{~A~^ ~}" name (third found))
                       case-lines))
                (t
                 (destructuring-bind (body-octets locals unimplemented) found
                   (declare (ignore unimplemented))
                   (let ((m (make-lisp-module))
                         (file (format nil "~A.wasm" (string-downcase name))))
                     (add-lisp-functions m (list (list (string-downcase name) body-octets locals)))
                     (write-wasm-module m (format nil "~A/~A" out-dir file))
                     (incf n-modules)
                     (dolist (args arg-lists)
                       (let ((expected (host-eval lambda-list body args)))
                         (push (format nil "~A 0 ~{~D ~}=> ~D ~A"
                                       file (mapcar #'target-word args)
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
