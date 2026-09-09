#!/bin/sh
# The warm load for the WebAssembly target (make-target-2.sh under the
# sbcl-wasm host): the cold core compiles the warm sources
# (src/cold/warm.lisp: PCL and the rest) with its own compiler, a fresh
# cold core loads them (make-target-2-load.lisp) and saves
# output/sbcl.core; the core module is copied beside it, and the modules
# compiled at run time are saved in the core (*WASM-LOADED-MODULES*).
#   tools-for-build/wasm-warm.sh [cold-core]     (default obj/xbuild/wasm.core)
# Logs: obj/wasm-build/warm-compile.log, warm-load.log. SBCL_WASM_TIMEOUT
# applies to each phase.
set -eu
cd "$(dirname "$0")/.."
. tools-for-build/wasm-env.sh
RUN=tools-for-build/wasm_run.sh
CORE=${1:-obj/xbuild/wasm.core}
# The compiler's transient garbage ages into the older generations
# before they are collected; the 512 MiB default fills up during the
# PCL compile (Sprints/Sprint8/develop.md).
HEAP="--dynamic-space-size ${SBCL_WASM_WARM_HEAP:-1536MB}"
log=obj/wasm-build
mkdir -p "$log" output obj/from-self
echo "== warm load, compile phase (log: $log/warm-compile.log)"
$RUN src/runtime/sbcl.wasm --core "$CORE" $HEAP --noinform --no-sysinit --no-userinit --disable-debugger \
    --eval '(sb-fasl::!warm-load "src/cold/warm.lisp")' --quit > "$log/warm-compile.log" 2>&1 \
    || { tail -40 "$log/warm-compile.log"; echo "warm compile failed (see $log/warm-compile.log)"; exit 1; }
echo "== warm load, load and save phase (log: $log/warm-load.log)"
$RUN src/runtime/sbcl.wasm --core "$CORE" $HEAP --noinform --no-sysinit --no-userinit --disable-debugger --noprint \
    > "$log/warm-load.log" 2>&1 <<'LISP' || { tail -40 "$log/warm-load.log"; echo "warm load failed (see $log/warm-load.log)"; exit 1; }
(sb-fasl::!warm-load "make-target-2-load.lisp")
(setf (extern-alien "gc_coalesce_string_literals" char) 2)
;;; Use the historical (bad) convention for *compile-file-pathname*
(setf sb-c::*merge-pathnames* t)
;;; and for storing pathname namestrings in fasls too.
(setq sb-c::*name-context-file-path-selector* 'truename)
; Turn off IR consistency checking in release mode.
(setq sb-c::*check-consistency* nil)
(sb-ext:save-lisp-and-die "output/sbcl.core")
LISP
cp obj/xbuild/wasm-core.wasm output/sbcl-core.wasm
ls -la output/sbcl.core output/sbcl-core.wasm
