#!/bin/sh
# Sprint 1 user-acceptance test: re-runs every spike and checks the
# outcome each one was designed to establish. Exit 0 when all pass.
# Usage: Sprints/Sprint1/uat.sh   (from the repository root)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
S="$ROOT/Sprints/Sprint1/spikes"
WASI_SDK=${WASI_SDK:-/home/user/tools/wasi-sdk}
pass=0; fail=0
ok()   { pass=$((pass+1)); echo "PASS  $1"; }
bad()  { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

echo "== tools"
check "wasmtime present"   "wasmtime --version"
check "wasm-tools present" "wasm-tools --version"
check "wasi-sdk clang present" "$WASI_SDK/bin/clang --version"
check "host sbcl present"  "sbcl --version"
check "node present"       "node --version"

echo "== S0.1 tool chain"
check "S0.1 runtime.wasm + plugin.wasm build with wasi-sdk" "$S/s01-toolchain/build.sh"
check "S0.1 hello world runs under wasmtime" "$WASI_SDK/bin/clang --target=wasm32-wasip1 -O2 -o $S/s01-toolchain/hello.wasm $S/s01-toolchain/runtime.c && wasmtime run $S/s01-toolchain/hello.wasm | grep -q 'sizeof(void\*)=4'"
check "S0.1 Rust host builds" "cd $ROOT/wasm && cargo build --release"
check "S0.1 runtime-instantiated module installs into shared table and is called via C" "$ROOT/wasm/target/release/spike-s01 $S/s01-toolchain | grep -q 'call_slot(base,21)=42 call_slot(base+1,21)=121 mem\[1024\]=121'"
check "S0.1 sbcl-wasm runner executes a WASI command module" "$ROOT/wasm/target/release/sbcl-wasm $S/s01-toolchain/hello.wasm | grep -q 'hello from'"

echo "== S0.2 exception handling and tail calls"
check "S0.2 eh.wat validates with all features" "cd $S/s02-eh-tailcall && wasm-tools parse eh.wat -o eh.wasm && wasm-tools validate --features all eh.wasm"
check "S0.2 node: unwind through 1000 frames catches at target 500" "cd $S/s02-eh-tailcall && node run.mjs | grep -q '\"unwind_1000_catch_at_500\": 500'"
check "S0.2 node: 10^7 direct and indirect tail calls do not overflow" "cd $S/s02-eh-tailcall && node run.mjs | grep -q '\"tail_indirect_1e7\": 10000000'"
check "S0.2 wasmtime: unwind through 1000 frames catches at target 500" "cd $S/s02-eh-tailcall && wasmtime run -W exceptions=y,tail-call=y --invoke unwind_test eh.wasm 1000 500 2>/dev/null | grep -qx 500"
check "S0.2 wasmtime: 10^7 indirect tail calls" "cd $S/s02-eh-tailcall && wasmtime run -W exceptions=y,tail-call=y --invoke tail_indirect_test eh.wasm 10000000 2>/dev/null | grep -qx 10000000"

echo "== S0.3 control-flow encodings"
check "S0.3 both encodings validate" "cd $S/s03-control-flow && wasm-tools parse structured.wat -o structured.wasm && wasm-tools parse dispatch.wat -o dispatch.wasm && wasm-tools validate structured.wasm && wasm-tools validate dispatch.wasm"
check "S0.3 node: dispatch-loop results equal structured results (bench.mjs asserts)" "cd $S/s03-control-flow && node bench.mjs > node-result.json"
check "S0.3 wasmtime: fib 32 equal in both encodings" "cd $S/s03-control-flow && [ \"\$(wasmtime run --invoke fib structured.wasm 32 2>/dev/null)\" = \"\$(wasmtime run --invoke fib dispatch.wasm 32 2>/dev/null)\" ]"

echo "== S0.4 runtime compile"
check "S0.4 genesis headers exist for the wasm target" "grep -q LISP_FEATURE_WASM $ROOT/src/runtime/genesis/sbcl.h && grep -q 'N_WORD_BITS 32' $ROOT/src/runtime/genesis/sbcl.h"
check "S0.4 target-os.h is the WASI stub" "[ \"\$(readlink $ROOT/src/runtime/target-os.h)\" = wasi-os.h ]"
check "S0.4 at least 32 of 42 runtime files compile to wasm32-wasip1" "$S/s04-runtime/compile-all.sh | grep -c '^OK' | awk '{exit !(\$1>=32)}'"

echo "== S0.5 dev loop"
check "S0.5 :wasm is a target keyword" "grep -q ':wasm' $ROOT/src/cold/shebang.lisp && grep -q ':wasm' $ROOT/src/cold/chill.lisp"
check "S0.5 make-host-1 produced the cross-compiler fasls for the wasm backend" "ls $ROOT/obj/from-host/src/compiler/wasm/call.fasl"
check "S0.5 crossbuild-runner built xc.core for wasm" "ls $ROOT/obj/xbuild/wasm/xc.core"
check "S0.5 crossbuild-runner built a wasm cold core" "ls $ROOT/obj/xbuild/wasm.core"

echo "== S0.6 wasm64"
check "S0.6 memory64 module validates" "cd $S/s06-wasm64 && wasm-tools parse mem64.wat -o mem64.wasm && wasm-tools validate --features memory64 mem64.wasm"
check "S0.6 wasmtime runs memory64 by default" "cd $S/s06-wasm64 && wasmtime run --invoke probe mem64.wasm 2>/dev/null | grep -qx 1311768467463790320"
check "S0.6 node runs memory64 by default" "cd $S/s06-wasm64 && node mem64.mjs | grep -q 'probe: 123456789abcdef0'"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
