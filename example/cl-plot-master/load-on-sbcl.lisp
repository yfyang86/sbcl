;;;; Load cl-plot on SBCL — the native one or the WebAssembly port:
;;;;
;;;;   tools-for-build/wasm_run.sh src/runtime/sbcl.wasm \
;;;;     --core output/sbcl.core --script example/cl-plot-master/load-on-sbcl.lisp
;;;;
;;;; (SBCL_HOME must point at obj/sbcl-home for (REQUIRE :ASDF) under
;;;; the port; build-wasm.sh contrib builds it.) cl-plot itself targets
;;;; ECL (EXT:SHELL, EXT:CD); ext-compat.lisp supplies those two on
;;;; SBCL first.

(require :asdf)
(let ((dir (make-pathname :name nil :type nil :version nil
                          :defaults *load-truename*)))
  (load (merge-pathnames "ext-compat.lisp" dir))
  (pushnew dir asdf:*central-registry*))
(asdf:load-system :cl-plot)
(format t "~&cl-plot loaded (EXT package: ~A symbols).~%"
        (length (loop for s being each external-symbol of :ext collect s)))
