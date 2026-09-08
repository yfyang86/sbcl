;;;; Cross-compile the whole source tree for the wasm target (make-host-2
;;;; in crossbuild-runner form) and save the resulting cross-compiler
;;;; image as obj/xbuild/wasm/after-xc.core. Missing VOP generators emit
;;;; UNREACHABLE (see VOP-NOT-YET-IMPLEMENTED), so the compile-time
;;;; effects of every file are available to the differential test rig,
;;;; and the unimplemented VOPs are reported to
;;;; obj/xbuild/wasm/unimplemented-vops.txt as the backend worklist.
;;;;
;;;; usage (from the repository root, in a fresh host SBCL, after
;;;; crossbuild-runner pass-1 has produced obj/xbuild/wasm/from-host):
;;;;   sbcl --noinform --disable-debugger --no-userinit --no-sysinit \
;;;;        --load tests/wasm/make-after-xc.lisp
;;;; Takes about ten minutes.

(defvar *config-name* "wasm")
(defvar *sbcl-local-target-features-file* "obj/xbuild/wasm/local-target-features")
(let ((sb-c::*handled-conditions* sb-c::*handled-conditions*))
  (declaim (muffle-conditions compiler-note))
  (load "src/cold/shared.lisp"))
(in-package "SB-COLD")
(let* ((build-dir "obj/xbuild/wasm/")
       (objroot (format nil "~A/from-xc/" build-dir)))
  (ensure-directories-exist objroot)
  (defparameter *host-obj-prefix* (format nil "~A/from-host/" build-dir))
  (defparameter *target-obj-prefix* objroot)
  (defparameter *build-dependent-generated-sources-root* objroot))
(load "src/cold/set-up-cold-packages.lisp")
(load "src/cold/defun-load-or-cload-xcompiler.lisp")
(load-or-cload-xcompiler #'host-load-stem)
(preload-perfect-hash-generator (perfect-hash-generator-journal :input))

;;; groveled headers come from the checked-in stand-in, as in pass-2
(host-sb-int:encapsulate 'stem-source-path 'wrap
  (lambda (realfun stem)
    (if (string= stem "output/stuff-groveled-from-headers")
        (format nil "crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp")
        (funcall realfun stem))))

(format t "~&Target features: ~S~%" sb-xc:*features*)
(let ((warnings (sb-xc:with-compilation-unit ()
                  (load "src/cold/compile-cold-sbcl.lisp")
                  sb-c::*undefined-warnings*)))
  (finish-output host-sb-sys:*stdout*)
  (finish-output host-sb-sys:*stderr*)
  (when warnings
    (format t "~&~D undefined warnings~%" (length warnings))))

(with-open-file (s "obj/xbuild/wasm/unimplemented-vops.txt" :direction :output :if-exists :supersede)
  (sb-vm::report-unimplemented-vops s))
(sb-vm::report-unimplemented-vops)
(finish-output host-sb-sys:*stdout*)
(host-sb-ext:save-lisp-and-die "obj/xbuild/wasm/after-xc.core")
