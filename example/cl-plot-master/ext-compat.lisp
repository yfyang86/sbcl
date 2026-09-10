;;;; A compatibility package for loading ECL-targeted modules on SBCL
;;;; (the WebAssembly port and native alike): cl-plot calls EXT:SHELL and
;;;; EXT:CD, which exist only on ECL. Load this file before the system:
;;;;
;;;;   (load "example/cl-plot-master/ext-compat.lisp")
;;;;
;;;; EXT:SHELL runs a command through SBCL's RUN-PROGRAM when the host
;;;; can spawn processes; on the WebAssembly target (wasi-p1 has no
;;;; process spawning) it reports the limitation instead of hanging the
;;;; image, after the plot's command and data files have been written.

(defpackage #:ext
  (:use #:cl)
  (:export #:shell #:cd))

(in-package #:ext)

(defun shell (command)
  ;; One string, the way ECL's ext:shell takes it: a program with its
  ;; arguments. Split on spaces; no quoting needs in cl-plot's use
  ;; (bash + a filename without spaces).
  (let ((parts (remove "" (split-string command) :test #'string=)))
    #+wasm
    (error "EXT:SHELL: this SBCL runs under WebAssembly (wasi-p1), which ~
            cannot spawn subprocesses; the plot commands are in the file ~
            the figure's stream wrote (run them outside the sandbox: ~
            `bash <cmd-file>` with gnuplot on PATH).")
    #-wasm
    (sb-ext:process-exit-code
     (sb-ext:run-program (first parts) (rest parts)
                         :search t :wait t
                         :output :interactive :error :interactive))))

(defun cd (&optional (directory (user-homedir-pathname)))
  ;; ECL's ext:cd changes and returns the current directory; SBCL's
  ;; convention is *DEFAULT-PATHNAME-DEFAULTS*.
  (setf *default-pathname-defaults*
        (truename (merge-pathnames directory *default-pathname-defaults*))))

(defun split-string (string &optional (separator #\Space))
  (loop for start = 0 then (1+ end)
        for end = (position separator string :start start)
        collect (subseq string start (or end (length string)))
        until (null end)))
