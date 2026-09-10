;;;; Calling JavaScript from the WebAssembly port of SBCL: the
;;;; skeleton (Sprint 14, doc/wasm-port/04-sprints.md "Sprint 14:
;;;; browser host"). The mechanism the design means (the runtime's
;;;; call_into_lisp and a host function the linkage table can fill,
;;;; SBCL-Handoff.md 4.6) has no JavaScript-facing entry yet; this file
;;;; fixes the package and the error every caller sees until it has.

(defpackage #:sb-js
  (:use #:cl)
  (:export #:js-call
           #:js-call-error
           #:*js-host-available*
           #:host-provides-js-call-p)
  (:documentation "The JavaScript interface of the SBCL WebAssembly port."))

(in-package #:sb-js)

(defvar *js-host-available* nil
  "Whether the running host answers JS-CALL. The Wasmtime host and the
Node smoke driver do not; a browser host that grows the entry point
sets this (and HOST-PROVIDES-JS-CALL-P's answer) when it loads.")

(define-condition js-call-error (error)
  ((function :reader js-call-function :initarg :function))
  (:report (lambda (condition stream)
             (format stream "~S: no JavaScript entry point in this host ~
                             (SBCL-Handoff.md 4.6; the sb-js skeleton)"
                     (js-call-function condition)))))

(defun host-provides-js-call-p ()
  *js-host-available*)

(defun js-call (function &rest arguments)
  "Call the host's JavaScript FUNCTION (a string name, or however the
host that grows the entry point names its functions) with ARGUMENTS,
returning what it returns. Signals JS-CALL-ERROR in every host of this
sprint: the runtime exports no JavaScript-facing entry point yet."
  (declare (ignore arguments))
  (error 'js-call-error :function function))
