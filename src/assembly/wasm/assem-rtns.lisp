;;;; assembly routines for the WebAssembly target: non-local exit and
;;;; the variable-argument tail call.
;;;;
;;;; On this target the routines are ordinary Wasm functions in the core
;;;; module. Sprint 2 defines them so that the VOPs they provide (THROW,
;;;; UNWIND) exist for the compiler front end; their bodies are written
;;;; in Sprint 3 on Wasm exception handling (doc/wasm-port/02-design.md, 2.6).

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.

(in-package "SB-VM")

(define-assembly-routine throw
  ((:arg target (descriptor-reg any-reg) a0-offset)
   (:arg start (descriptor-reg any-reg) ocfp-offset)
   (:arg count (descriptor-reg any-reg) nargs-offset)
   (:temp catch any-reg a1-offset)
   (:temp tag descriptor-reg a2-offset))
  (declare (ignore target start count catch tag))
  (vop-not-yet-implemented 'throw))

(define-assembly-routine (unwind
                          (:translate %unwind)
                          (:policy :fast-safe))
  ((:arg block (descriptor-reg any-reg) a0-offset)
   (:arg start (descriptor-reg any-reg) ocfp-offset)
   (:arg count (descriptor-reg any-reg) nargs-offset)
   (:temp cur-uwp any-reg nl0-offset)
   (:temp temp any-reg nl1-offset)
   (:temp target-uwp any-reg nl2-offset))
  (declare (ignore block start count cur-uwp temp target-uwp))
  (vop-not-yet-implemented 'unwind))
