#!/bin/sh
# Sprint 3 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 2, "function assembler and simple VOPs"):
#   - the cross-compiler builds with the real VOP generators (pass-1) and
#     the whole tree cross-compiles with tolerant placeholders (after-xc)
#   - level 0 still passes, including the function assembler tests
#   - the mini-runtime and the Rust differential driver build
#   - at least fifty level-1 differential cases pass under wasmtime,
#     with every module validated by wasm-tools and no failures
# UAT_FAST=1 skips the two Lisp builds (about fifteen minutes) and checks
# their products instead.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== cross-compiler"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "xc.core present (fast mode)" "ls obj/xbuild/wasm/xc.core"
  check "after-xc.core present (fast mode)" "ls obj/xbuild/wasm/after-xc.core"
else
  check "crossbuild pass-1 builds obj/xbuild/wasm/xc.core" "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/xc.core && Sprints/Sprint3/pass1.sh && ls obj/xbuild/wasm/xc.core"
  check "the whole tree cross-compiles into after-xc.core" "Sprints/Sprint3/after-xc.sh && ls obj/xbuild/wasm/after-xc.core"
fi
check "pass-1 log has no warnings" "! grep -aq 'caught WARNING\|caught STYLE-WARNING' Sprints/Sprint3/crossbuild-pass-1.log"
check "unimplemented VOP worklist written" "test -s obj/xbuild/wasm/unimplemented-vops.txt"
check "no placeholder generators remain in the simple VOP families" "! grep -q 'vop-not-yet-implemented' src/compiler/wasm/arith.lisp src/compiler/wasm/pred.lisp src/compiler/wasm/char.lisp src/compiler/wasm/move.lisp src/compiler/wasm/memory.lisp src/compiler/wasm/sap.lisp src/compiler/wasm/type-vops.lisp src/compiler/wasm/debug.lisp"

echo "== level 0"
if tests/wasm/run-level0.sh > Sprints/Sprint3/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' Sprints/Sprint3/level0.log) checks, all modules validate and run"; else bad "level-0 (see Sprints/Sprint3/level0.log)"; fi
check "level-0 ran the function assembler tests (dispatch loop, jump table)" "grep -q 'PASS run funcasm.sum10' Sprints/Sprint3/level0.log && grep -q 'PASS run funcasm.pick' Sprints/Sprint3/level0.log"

echo "== differential rig"
check "mini-runtime builds (wasi-sdk)" "tests/wasm/build-minirt.sh && ls tests/wasm/minirt.wasm"
check "Rust driver builds" "(cd wasm && cargo build --release -p sbcl-wasm-test) && ls wasm/target/release/sbcl-wasm-test"

echo "== level 1"
if XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > Sprints/Sprint3/level1.log 2>&1; then
  ok "level-1: $(grep '^level1:' Sprints/Sprint3/level1.log)"
else
  bad "level-1 (see Sprints/Sprint3/level1.log)"
fi
passed=$(grep '^level1:' Sprints/Sprint3/level1.log | sed 's/.*passed=\([0-9]*\).*/\1/')
check "at least fifty level-1 cases pass (got ${passed:-0})" "[ \"${passed:-0}\" -ge 50 ]"
check "no case skipped (not compiled or unimplemented VOP)" "! grep -q '^# .*: ' Sprints/Sprint3/level1.log"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
