#!/bin/sh
# Sprint 7 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 6, "cold init"):
#   - !cold-init runs to toplevel-init and the REPL
#   - sbcl-wasm src/runtime/sbcl.wasm --core obj/xbuild/wasm.core
#       --eval '(print (+ 1 2))' prints 3
#   - code compiled at run time is loaded and called (the runtime code loader)
#   - nothing regressed: level 0, level 1, the Sprint 6 checks
# UAT_FAST=1 skips the Lisp builds (about twenty minutes) and checks their
# products instead. Uses build-wasm.sh (see WASM-Manual.md).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
S=Sprints/Sprint7
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
. tools-for-build/wasm-env.sh
RUN=tools-for-build/wasm_run.sh

echo "== toolchain"
check "wasi-sdk present" "test -x $WASI_SDK/bin/clang"
check "host builds (sbcl-wasm)" "./build-wasm.sh host > $S/host.log 2>&1 && ls wasm/target/release/sbcl-wasm"
check "groveled constants are up to date (wasm-grovel-headers.sh reproduces the file)" \
  "tools-for-build/wasm-grovel-headers.sh $S/groveled.lisp > $S/grovel.log 2>&1 && diff -q $S/groveled.lisp crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp && rm -f $S/groveled.lisp"

echo "== Lisp side"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "pass-2 products present (fast mode)" "ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm obj/xbuild/wasm-core.wasm.symbols obj/xbuild/wasm.map obj/xbuild/wasm/genesis-headers/sbcl.h"
else
  check "build-wasm.sh lisp: pass-1 and pass-2 (xc.core, wasm.core, the core module)" \
    "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/from-xc obj/xbuild/wasm/xc.core obj/xbuild/wasm.core && ./build-wasm.sh --jobs 4 lisp > $S/lisp.log 2>&1 && ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm"
fi
check "the core module validates (wasm-tools, all features)" "wasm-tools validate --features all obj/xbuild/wasm-core.wasm"
check "genesis wrote the map file" "test -s obj/xbuild/wasm.map && grep -q 'SB-KERNEL:!COLD-INIT' obj/xbuild/wasm.map"
check "genesis gave the target the routine table and the next free table index" \
  "grep -q 'SB-VM::\*WASM-ROUTINE-TABLE\*' obj/xbuild/wasm.map && grep -q 'SB-VM::\*WASM-TABLE-NEXT\*' obj/xbuild/wasm.map"

echo "== runtime"
if ./build-wasm.sh runtime > $S/build-runtime.log 2>&1; then ok "runtime builds: src/runtime/sbcl.wasm"; else bad "runtime build (see $S/build-runtime.log)"; fi
check "runtime build has no warnings" "! grep -q 'warning:' $S/build-runtime.log"
check "sbcl.wasm validates" "wasm-tools validate --features all src/runtime/sbcl.wasm"
check "sbcl.wasm exports the allocation, error, interrupt and module-loading entry points" \
  "wasm-tools print src/runtime/sbcl.wasm | grep -c '(export \"\\(alloc\\|alloc_list\\|internal_error\\|pending_interrupt\\|memory\\|__indirect_function_table\\)\"' | grep -qx 6"

echo "== cold init"
SBCL_WASM_VERBOSE=1 SBCL_WASM_TIMEOUT=600 $RUN src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit --non-interactive --eval '(print (+ 1 2))' > $S/cold-init.txt 2>&1
echo "      last line: $(grep -v '^\s*$' $S/cold-init.txt | tail -1 | cut -c1-100)"
check "the core module instantiates against the runtime" "grep -q 'sbcl-wasm: module of .* functions at table 4096' $S/cold-init.txt"
check "cold-init prints through Lisp streams (stream init done)" "grep -q 'SIGBUS handler not installed' $S/cold-init.txt"
check "run-time compiled code is loaded as a module (the first COMPILE at cold init)" "grep -c 'sbcl-wasm: module of .* functions at table' $S/cold-init.txt | awk '{exit !(\$1 >= 2)}'"
check "no unknown import, no internal error, no deadline" "! grep -q 'unknown import\|internal error\|deadline of' $S/cold-init.txt"
check "EXIT CRITERION: --eval '(print (+ 1 2))' prints 3" "grep -q '^3 *$' $S/cold-init.txt"
$RUN src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit --non-interactive --eval '(progn (print (list (lisp-implementation-type) (lisp-implementation-version))) (terpri))' > $S/version.txt 2>&1
check "(lisp-implementation-version) at the REPL" "grep -q 'SBCL' $S/version.txt"
echo "(defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (print (fib 20)) (terpri)" | SBCL_WASM_TIMEOUT=600 $RUN src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit --disable-debugger > $S/repl.txt 2>&1
check "the REPL reads stdin, compiles a definition and calls it (fib 20 = 6765)" "grep -q '6765' $S/repl.txt"
$RUN src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit --non-interactive --eval '(handler-case (car (read-from-string "3")) (error (e) (print (type-of e)) (princ e) (terpri)))' > $S/error.txt 2>&1
check "an internal error enters Lisp: (car 3) at run time signals TYPE-ERROR, handler-case catches it" "grep -q '^TYPE-ERROR' $S/error.txt && grep -q 'is not of type' $S/error.txt"
if $RUN src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit --non-interactive --eval '(car (read-from-string "3"))' > $S/unhandled.txt 2>&1; then bad "an unhandled error under --non-interactive should exit nonzero"; else
  check "an unhandled error prints the condition and the erring frame, exits 1" "grep -q 'Unhandled TYPE-ERROR' $S/unhandled.txt && grep -q '(CAR ' $S/unhandled.txt"; fi
$RUN src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit --non-interactive --eval '(sb-ext:exit :code 7)' > /dev/null 2>&1; code=$?
if [ "$code" = 7 ]; then ok "(exit :code 7) exits 7 (unwinding through the end-of-the-world catch)"; else bad "(exit :code 7) exited $code"; fi

echo "== regressions (Sprint 6)"
check "--version" "$RUN src/runtime/sbcl.wasm --version | grep -q '^SBCL '"
check "--help" "$RUN src/runtime/sbcl.wasm --help | grep -q 'Usage: sbcl'"
check "spin test program compiles" "$WASI_SDK/bin/clang --target=wasm32-wasip1 -O2 -o $S/spin.wasm tests/wasm/spin.c"
if SBCL_WASM_TIMEOUT=2 $RUN $S/spin.wasm > $S/spin-deadline.txt 2>&1; then bad "deadline: spin.wasm should not exit normally"; else
  check "deadline stops a spinning module with a backtrace" "grep -q 'deadline of 2 s' $S/spin-deadline.txt && grep -q 'wasm backtrace' $S/spin-deadline.txt"; fi
check "coreindex.py decodes the map (finds !COLD-INIT by address)" "python3 tools-for-build/wasm-coreindex.py addr:\$(grep -m1 'SB-KERNEL:!COLD-INIT' obj/xbuild/wasm.map | awk '{print \$2}') | grep -q 'COLD-INIT'"

echo "== regressions (levels 0 and 1)"
if tests/wasm/run-level0.sh > $S/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' $S/level0.log) checks"; else bad "level-0 (see $S/level0.log)"; fi
if [ "${UAT_FAST:-0}" != 1 ] || [ ! -f obj/xbuild/wasm/after-xc.core ]; then
  check "after-xc core for the level-1 suite" "Sprints/Sprint5/after-xc.sh > $S/after-xc.log 2>&1 && ls obj/xbuild/wasm/after-xc.core"
fi
if XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > $S/level1.log 2>&1; then
  ok "level-1: $(grep '^level1:' $S/level1.log)"
else
  bad "level-1 (see $S/level1.log)"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
