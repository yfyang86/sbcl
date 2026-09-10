;;; -*-  Lisp -*-
(error "Can't build contribs with ASDF")

;;;; The sb-js contrib of the WebAssembly port (Sprint 14): the
;;;; skeleton of the JavaScript interface. What exists is JS-CALL's
;;;; error: calling JavaScript from Lisp needs a host-provided entry
;;;; point the runtime does not export yet (SBCL-Handoff.md 4.6); the
;;;; package, its symbols and this error are the seam the entry point
;;;; will plug into.

(defsystem "sb-js"
    :description "Calling JavaScript from the WebAssembly port of SBCL (skeleton)."
    :components ((:file "call")))
