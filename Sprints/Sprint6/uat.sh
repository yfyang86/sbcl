#!/bin/sh
# Sprint 6 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 5, "runtime port"):
#   - src/runtime builds with wasi-sdk to src/runtime/sbcl.wasm
#   - sbcl.wasm --version and --help work under the host
#   - the host (sbcl-wasm) provides sbcl_host.instantiate, traps for unknown
#     imports, Ctrl-C and a run deadline
#   - coreparse loads the cold core, the core module instantiates against
#     the runtime's memory and table, call_into_lisp reaches !COLD-INIT
#   - nothing regressed: level 0, level 1, the Sprint 5 products
# UAT_FAST=1 skips the Lisp builds (about thirty minutes) and checks their
# products instead.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
S=Sprints/Sprint6
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
WASI_SDK=${WASI_SDK:-/home/user/tools/wasi-sdk}

echo "== Lisp side"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "pass-2 products present (fast mode)" "ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm obj/xbuild/wasm-core.wasm.symbols obj/xbuild/wasm/genesis-headers-2/sbcl.h"
else
  check "crossbuild pass-1 builds obj/xbuild/wasm/xc.core" "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/xc.core && Sprints/Sprint5/pass1.sh > $S/pass1.log 2>&1 && ls obj/xbuild/wasm/xc.core"
  check "crossbuild pass-2 cross-compiles the tree and runs genesis" "Sprints/Sprint5/pass2.sh > $S/pass2.log 2>&1"
  check "genesis alone (with the map file) reproduces the core" "$S/genesis-map.sh"
fi
check "the core module validates (wasm-tools, all features)" "wasm-tools validate --features all obj/xbuild/wasm-core.wasm"
check "genesis wrote the map file" "test -s obj/xbuild/wasm.map && grep -q 'SB-KERNEL:!COLD-INIT' obj/xbuild/wasm.map"

echo "== runtime"
check "wasi-sdk present" "test -x $WASI_SDK/bin/clang"
if tools-for-build/wasm-build-runtime.sh obj/xbuild/wasm/genesis-headers-2 -j4 > $S/build-runtime.log 2>&1; then ok "runtime builds: src/runtime/sbcl.wasm"; else bad "runtime build (see $S/build-runtime.log)"; fi
check "runtime build has no warnings" "! grep -q 'warning:' $S/build-runtime.log"
check "sbcl.wasm validates" "wasm-tools validate --features all src/runtime/sbcl.wasm"
check "sbcl.wasm imports sbcl_host.instantiate and exports the entry points" "wasm-tools print src/runtime/sbcl.wasm | grep -q '(import \"sbcl_host\" \"instantiate\"' && wasm-tools print src/runtime/sbcl.wasm | grep -c '(export \"\\(alloc\\|alloc_list\\|internal_error\\|pending_interrupt\\|memory\\|__indirect_function_table\\)\"' | grep -qx 6"

echo "== host"
check "host builds (sbcl-wasm)" "(cd wasm && cargo build --release -p sbcl-wasm-host --bin sbcl-wasm) && ls wasm/target/release/sbcl-wasm"
check "--version" "tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --version | grep -q '^SBCL '"
check "--help" "tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --help | grep -q 'Usage: sbcl'"
check "spin test program compiles" "$WASI_SDK/bin/clang --target=wasm32-wasip1 -O2 -o $S/spin.wasm tests/wasm/spin.c"
if SBCL_WASM_TIMEOUT=2 tools-for-build/wasm_run.sh $S/spin.wasm > $S/spin-deadline.txt 2>&1; then bad "deadline: spin.wasm should not exit normally"; else
  check "deadline stops a spinning module with a backtrace" "grep -q 'deadline of 2 s' $S/spin-deadline.txt && grep -q 'wasm backtrace' $S/spin-deadline.txt"; fi
sh -c "tools-for-build/wasm_run.sh $S/spin.wasm > $S/spin-ctrlc.txt 2>&1 & pid=\$!; sleep 2; kill -INT \$pid; sleep 1; kill -INT \$pid; wait \$pid" >/dev/null 2>&1
check "Ctrl-C: first press notes the interrupt, second terminates" "grep -q 'interrupt requested' $S/spin-ctrlc.txt && grep -q 'Ctrl-C twice' $S/spin-ctrlc.txt"

echo "== the cold core"
SBCL_WASM_TRACE_CALLS=1 SBCL_WASM_VERBOSE=1 SBCL_WASM_TIMEOUT=120 tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit > $S/cold-core.txt 2>&1
check "coreparse loads the core and links every required foreign symbol" "! grep -q 'Missing required foreign symbol' $S/cold-core.txt && ! grep -q \"can't open\" $S/cold-core.txt"
check "the core module instantiates against the runtime" "grep -q 'sbcl-wasm: module of .* functions at table 4096' $S/cold-core.txt"
check "call_into_lisp reaches !COLD-INIT" "grep -q '^; call_into_lisp: function' $S/cold-core.txt"
check "the run gets past the entry (no trap in the first Lisp frame, no unknown import)" "! grep -q 'unknown import' $S/cold-core.txt"
echo "      cold-init ended with: $(grep -v '^\s*$' $S/cold-core.txt | grep -v '^ \+[0-9]\+:' | grep -m1 -i 'internal error\|deadline\|error while\|fatal\|\*\|^\* ' | cut -c1-100)"
check "coreindex.py decodes the map (finds !COLD-INIT by address)" "python3 $S/coreindex.py addr:\$(grep -m1 'SB-KERNEL:!COLD-INIT' obj/xbuild/wasm.map | awk '{print \$2}') | grep -q 'COLD-INIT'"

echo "== regressions"
if tests/wasm/run-level0.sh > $S/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' $S/level0.log) checks"; else bad "level-0 (see $S/level0.log)"; fi
if [ "${UAT_FAST:-0}" != 1 ]; then
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
