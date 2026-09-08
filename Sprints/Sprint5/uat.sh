#!/bin/sh
# Sprint 5 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 4, "genesis, fasls and the core module"):
#   - crossbuild-runner pass-2 produces a wasm cold core and a core module
#     that validates
#   - pass-1 and pass-2 genesis headers are identical
#   - the core module loads (not runs) in Wasmtime and V8, with size and
#     compile time recorded
#   - the required foreign symbols are listed for the runtime
#   - nothing regressed: level 0, and the level-1 differential suite
# UAT_FAST=1 skips the Lisp builds (about thirty minutes) and checks their
# products instead.
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
  check "pass-2 products present (fast mode)" "ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm"
else
  check "crossbuild pass-1 builds obj/xbuild/wasm/xc.core" "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/xc.core && Sprints/Sprint5/pass1.sh && ls obj/xbuild/wasm/xc.core"
  check "crossbuild pass-2 cross-compiles the tree and runs genesis" "Sprints/Sprint5/pass2.sh"
fi
check "pass-1 log has no warnings" "! grep -aq 'caught WARNING\|caught STYLE-WARNING\|WARNING: redefining' Sprints/Sprint5/crossbuild-pass-1.log"
check "the cold core obj/xbuild/wasm.core was written" "test -s obj/xbuild/wasm.core"
check "the core module obj/xbuild/wasm-core.wasm was written" "test -s obj/xbuild/wasm-core.wasm"
check "the core module validates (wasm-tools, all features)" "wasm-tools validate --features all obj/xbuild/wasm-core.wasm"
check "the required foreign symbols were listed" "test -s obj/xbuild/wasm-core.wasm.symbols && grep -q ' function ' obj/xbuild/wasm-core.wasm.symbols"

echo "== genesis headers"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "genesis-only run present (fast mode)" "ls obj/xbuild/wasm/genesis-headers-1 obj/xbuild/wasm/genesis-headers-2"
else
  check "genesis alone reproduces the core and writes both header sets" "Sprints/Sprint5/genesis-only.sh && ls obj/xbuild/wasm/genesis-headers-1 obj/xbuild/wasm/genesis-headers-2"
fi
check "pass-1 style and pass-2 genesis headers are identical" "diff -r -q obj/xbuild/wasm/genesis-headers-1 obj/xbuild/wasm/genesis-headers-2"

echo "== loaders"
check "Rust loader builds" "(cd wasm && cargo build --release -p sbcl-wasm-test) && ls wasm/target/release/load-core"
if wasm/target/release/load-core obj/xbuild/wasm-core.wasm > Sprints/Sprint5/load-core-wasmtime.txt 2>&1; then ok "core module loads in Wasmtime: $(grep -E '^(size|compile|instantiate):' Sprints/Sprint5/load-core-wasmtime.txt | tr '\n' ' ')"; else bad "core module in Wasmtime (see Sprints/Sprint5/load-core-wasmtime.txt)"; fi
if node --experimental-wasm-exnref tests/wasm/load-core.mjs obj/xbuild/wasm-core.wasm > Sprints/Sprint5/load-core-v8.txt 2>&1; then ok "core module loads in V8 (node): $(grep -E '^(compile|instantiate):' Sprints/Sprint5/load-core-v8.txt | tr '\n' ' ')"; else bad "core module in V8 (see Sprints/Sprint5/load-core-v8.txt)"; fi

echo "== regressions"
if tests/wasm/run-level0.sh > Sprints/Sprint5/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' Sprints/Sprint5/level0.log) checks"; else bad "level-0 (see Sprints/Sprint5/level0.log)"; fi
if [ "${UAT_FAST:-0}" != 1 ]; then
  check "after-xc core for the level-1 suite" "Sprints/Sprint5/after-xc.sh && ls obj/xbuild/wasm/after-xc.core"
fi
if XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > Sprints/Sprint5/level1.log 2>&1; then
  ok "level-1: $(grep '^level1:' Sprints/Sprint5/level1.log)"
else
  bad "level-1 (see Sprints/Sprint5/level1.log)"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
