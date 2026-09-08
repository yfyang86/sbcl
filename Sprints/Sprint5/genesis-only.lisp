;;;; Rerun genesis alone on the fasls pass-2 compiled (obj/xbuild/wasm/from-xc),
;;;; writing the cold core, the core module and the genesis headers into
;;;; obj/xbuild/wasm/genesis-headers-2; then genesis the way make-host-1
;;;; runs it (no object files, headers only) into genesis-headers-1, for
;;;; the comparison of the two (crossbuild-runner's pass-1 writes no
;;;; headers, being a :crossbuild-test build):
;;;;   sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
;;;;        wasm < Sprints/Sprint5/genesis-only.lisp
(defvar *config-name* (second sb-ext:*posix-argv*))
(defvar *sbcl-local-target-features-file*
  (format nil "obj/xbuild/~A/local-target-features" *config-name*))
(let ((sb-c::*handled-conditions* sb-c::*handled-conditions*))
  (declaim (muffle-conditions compiler-note))
  (load "src/cold/shared.lisp"))
(in-package "SB-COLD")
(let* ((build-dir (format nil "obj/xbuild/~A/" cl-user::*config-name*))
       (objroot (format nil "~A/from-xc/" build-dir)))
  (defparameter *host-obj-prefix* (format nil "~A/from-host/" build-dir))
  (defparameter *target-obj-prefix* objroot)
  (defparameter *build-dependent-generated-sources-root* objroot))
(load "src/cold/set-up-cold-packages.lisp")
(load "src/cold/defun-load-or-cload-xcompiler.lisp")
(load-or-cload-xcompiler #'host-load-stem)
(preload-perfect-hash-generator (perfect-hash-generator-journal :input))
(host-sb-int:encapsulate 'stem-source-path 'wrap
  (lambda (realfun stem)
    (if (string= stem "output/stuff-groveled-from-headers")
        "crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp"
        (funcall realfun stem))))
(load "tools-for-build/corefile.lisp" :verbose nil)
(host-cload-stem "src/compiler/generic/genesis" nil)
(let (object-file-names)
  (do-stems-and-flags (stem flags 2)
    (unless (member :not-target flags)
      (push (stem-object-path stem flags :target-compile) object-file-names)))
  (genesis :object-file-names (nreverse object-file-names)
           :defstruct-descriptions (find-bootstrap-file "output/defstructs.lisp-expr" t)
           :tls-init (read-from-file "output/tls-init.lisp-expr" :build-dependent t)
           :core-file-name (format nil "obj/xbuild/~A.core" cl-user::*config-name*)
           :c-header-dir-name (format nil "obj/xbuild/~A/genesis-headers-2" cl-user::*config-name*)))
(genesis :c-header-dir-name (format nil "obj/xbuild/~A/genesis-headers-1" cl-user::*config-name*))
