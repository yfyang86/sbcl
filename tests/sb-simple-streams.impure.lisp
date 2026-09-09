;;; the WebAssembly port: contrib not built on this target (SBCL_WASM_CONTRIB_BLOCKLIST)
#+wasm (invoke-restart 'run-tests::skip-file)

#+gc-stress (invoke-restart 'run-tests::skip-file)

(require :sb-simple-streams)
;; impure tests don't use the input manifest under run-tests.sh
;; but do under parallel-exec, which runs each test as if pure,
;; but in a forked child.
#+parallel-test-runner (setq run-tests::*allowed-inputs* :any)
(load "../contrib/sb-simple-streams/simple-stream-tests.lisp")
