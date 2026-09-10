;;;; assembly routines for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Non-local exit noise (doc/wasm-port/02-design.md, 2.6).
;;;;
;;;; THROW finds the catch block for TARGET and unwinds to it. UNWIND
;;;; runs the unwind-protect cleanups between here and BLOCK by entering
;;;; them one at a time (each cleanup calls UNWIND again for the same
;;;; block), then enters BLOCK: it stores the block in the thread's
;;;; unwind target, restores the block's frame and code, and throws the
;;;; LISP_UNWIND tag, which the handler of the block's function catches
;;;; (see func-asm.lisp). Neither routine returns.

(define-assembly-routine throw
  ((:arg target (descriptor-reg any-reg) a0-offset)
   (:arg start (descriptor-reg any-reg) ocfp-offset)
   (:arg count (descriptor-reg any-reg) nargs-offset)
   (:temp catch any-reg a1-offset)
   (:temp tag descriptor-reg a2-offset))
  (declare (ignore start count)) ; We only need them in the registers.
  (load-current-catch-block catch)
  LOOP
  (let ((error (generate-error-code nil 'unseen-throw-tag-error target)))
    (load-reg catch)
    (inst i32.eqz)
    (inst jump-if error))
  (loadw tag catch catch-block-tag-slot)
  (load-reg tag)
  (load-reg target)
  (inst i32.eq)
  (inst jump-if EXIT)
  (loadw catch catch catch-block-previous-catch-slot)
  (inst jump LOOP)
  EXIT
  (move target catch) ;; TARGET coincides with UNWIND's BLOCK argument
  (emit-lisp-call-args)
  (inst return_call (make-fixup 'unwind :assembly-routine)))

(define-assembly-routine (unwind
                          (:translate %unwind)
                          (:policy :fast-safe))
  ((:arg block (descriptor-reg any-reg) a0-offset)
   (:arg start (descriptor-reg any-reg) ocfp-offset)
   (:arg count (descriptor-reg any-reg) nargs-offset)
   (:temp cur-uwp any-reg nl0-offset)
   (:temp target-uwp any-reg nl2-offset))
  (declare (ignore start count))
  (let ((error (generate-error-code nil 'invalid-unwind-error)))
    (load-reg block)
    (inst i32.eqz)
    (inst jump-if error))
  (load-current-unwind-protect-block cur-uwp)
  (loadw target-uwp block unwind-block-uwp-slot)
  (load-reg cur-uwp)
  (load-reg target-uwp)
  (inst i32.ne)
  (inst jump-if DO-UWP)
  (move cur-uwp block)
  DO-EXIT
  (inst global.get +thread-global+)
  (load-reg cur-uwp)
  (inst i32.store +thread-unwind-target-offset+)
  (loadw cfp-tn cur-uwp unwind-block-cfp-slot)
  (loadw code-tn cur-uwp unwind-block-code-slot)
  (inst throw +tag-lisp-unwind+)
  DO-UWP
  (loadw target-uwp cur-uwp unwind-block-uwp-slot)
  (store-current-unwind-protect-block target-uwp)
  (inst jump DO-EXIT))

;;;; Trampolines called through an fdefn (see cell.lisp): LEXENV holds
;;;; the fdefn, NARGS and the argument registers are set.

;;; The fdefn names a closure (or a funcallable instance): call the
;;; function object the way CALL does.
(define-assembly-routine (closure-tramp (:return-style :none))
    ((:temp lexenv descriptor-reg lexenv-offset)
     (:temp function descriptor-reg l0-offset))
  (loadw lexenv lexenv fdefn-fun-slot other-pointer-lowtag)
  (emit-function-object-entry lexenv function)
  (emit-full-call function t))

;;; The fdefn is unbound.
(define-assembly-routine (undefined-tramp (:return-style :none))
    ((:temp lexenv descriptor-reg lexenv-offset))
  (let ((error (generate-error-code nil 'undefined-fun-error lexenv)))
    (inst jump error)))
