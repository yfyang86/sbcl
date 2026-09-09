;;; the WebAssembly port: contrib not built on this target (SBCL_WASM_CONTRIB_BLOCKLIST)
#+wasm (invoke-restart 'run-tests::skip-file)

(require :sb-bsd-sockets)
#-win32 (require :sb-posix)
(load "../contrib/sb-bsd-sockets/tests.lisp")
