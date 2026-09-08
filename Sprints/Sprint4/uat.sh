#!/bin/sh
# Sprint 4 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 3, "calls, frames, allocation, floats, NLX"):
#   - the cross-compiler builds (pass-1) without warnings and the whole
#     tree cross-compiles (after-xc) with ZERO unimplemented VOPs
#   - no placeholder generator remains in src/compiler/wasm
#   - level 0 still passes (function assembler included)
#   - the mini-runtime, the assembly-routine module and the Rust driver build
#   - the level-1 differential cases pass under wasmtime, including the
#     Sprint 4 families: local calls, unknown values, catch/throw,
#     unwind-protect, dynamic extent, optional/rest entry points, floats
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
  check "crossbuild pass-1 builds obj/xbuild/wasm/xc.core" "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/xc.core && Sprints/Sprint4/pass1.sh && ls obj/xbuild/wasm/xc.core"
  check "the whole tree cross-compiles into after-xc.core" "Sprints/Sprint4/after-xc.sh && ls obj/xbuild/wasm/after-xc.core"
fi
check "pass-1 log has no warnings" "! grep -aq 'caught WARNING\|caught STYLE-WARNING\|WARNING: redefining' Sprints/Sprint4/crossbuild-pass-1.log"
check "after-xc used no unimplemented VOP (worklist empty)" "grep -q '^0 unimplemented VOPs' obj/xbuild/wasm/unimplemented-vops.txt"
check "no placeholder generator remains in src/compiler/wasm" "! grep -l 'vop-not-yet-implemented' src/compiler/wasm/*.lisp | grep -v macros.lisp"

echo "== level 0"
if tests/wasm/run-level0.sh > Sprints/Sprint4/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' Sprints/Sprint4/level0.log) checks, all modules validate and run"; else bad "level-0 (see Sprints/Sprint4/level0.log)"; fi

echo "== differential rig"
check "mini-runtime builds (wasi-sdk)" "tests/wasm/build-minirt.sh && ls tests/wasm/minirt.wasm"
check "Rust driver builds" "(cd wasm && cargo build --release -p sbcl-wasm-test) && ls wasm/target/release/sbcl-wasm-test"

echo "== level 1"
if XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > Sprints/Sprint4/level1.log 2>&1; then
  ok "level-1: $(grep '^level1:' Sprints/Sprint4/level1.log)"
else
  bad "level-1 (see Sprints/Sprint4/level1.log)"
fi
passed=$(grep '^level1:' Sprints/Sprint4/level1.log | sed 's/.*passed=\([0-9]*\).*/\1/')
check "at least 400 level-1 argument sets pass (got ${passed:-0})" "[ \"${passed:-0}\" -ge 400 ]"
check "no case skipped (not compiled or unimplemented VOP)" "! grep -q '^# .*: ' Sprints/Sprint4/level1.log"
check "the assembly-routine module was built and validates" "ls obj/wasm-level1/asm.wasm && wasm-tools validate --features all obj/wasm-level1/asm.wasm"
for family in labels-fib-rec mv-unknown-local catch-throw-from-local uwp-throw dx-list optional-two rest-sum sf-mul df-round; do
  check "level-1 family '$family' passes" "grep -q \"^PASS $family \" Sprints/Sprint4/level1.log"
done

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
