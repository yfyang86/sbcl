#!/bin/sh
# Sprint 2 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 1, "target definition and assembler"):
#   - make-host-1 builds the wasm cross-compiler from the new backend and
#     genesis pass 1 writes the headers
#   - crossbuild-runner pass-1 builds obj/xbuild/wasm/xc.core
#   - the level-0 tests pass, every emitted module validates with
#     wasm-tools, and the exported functions run under wasmtime
# UAT_FAST=1 skips the two builds (about six minutes) and checks their
# products instead.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
XC='sbcl --dynamic-space-size 2GB --lose-on-corruption --disable-ldb --disable-debugger'

echo "== configuration"
check "make-config accepts --arch=wasm" "sh make-config.sh --arch=wasm --xc-host='$XC' > Sprints/Sprint2/make-config.log 2>&1"
check "features: :wasm :soft-card-marks :gencgc, no :64-bit" "grep -q ':wasm' local-target-features.lisp-expr && grep -q ':soft-card-marks' local-target-features.lisp-expr && ! grep -q ':64-bit' local-target-features.lisp-expr"

echo "== make-host-1 (cross-compiler and genesis headers)"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "make-host-1 products present (fast mode)" "ls obj/from-host/src/compiler/wasm/module.fasl obj/from-host/src/compiler/wasm/call.fasl"
else
  check "make-host-1 succeeds for the wasm backend" "sh make-host-1.sh > Sprints/Sprint2/make-host-1.log 2>&1"
fi
check "sbcl.h: LISP_FEATURE_WASM, 32-bit words" "grep -q 'define LISP_FEATURE_WASM' src/runtime/genesis/sbcl.h && grep -q 'define N_WORD_BITS 32' src/runtime/genesis/sbcl.h"
check "sbcl.h: soft card marks, 32 cards per 32 KiB page" "grep -q 'define LISP_FEATURE_SOFT_CARD_MARKS' src/runtime/genesis/sbcl.h && grep -q 'define CARDS_PER_PAGE 32' src/runtime/genesis/sbcl.h && grep -q 'define BACKEND_PAGE_BYTES 32768' src/runtime/genesis/sbcl.h"
check "sbcl.h: static space at 17 MiB, 4-byte linkage entries" "grep -q 'define STATIC_SPACE_START 17825792' src/runtime/genesis/sbcl.h && grep -q 'define ALIEN_LINKAGE_TABLE_ENTRY_SIZE 4' src/runtime/genesis/sbcl.h"
check "no riscv instruction names remain in the backend" "! grep -q 'define-riscvi\|(inst addi\|(inst jal' src/compiler/wasm/*.lisp src/assembly/wasm/*.lisp"

echo "== crossbuild-runner pass-1"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "xc.core present (fast mode)" "ls obj/xbuild/wasm/xc.core"
else
  check "crossbuild pass-1 builds obj/xbuild/wasm/xc.core" "rm -rf obj/xbuild/wasm && sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit wasm wasm '(:UNIX :LINUX :ELF :OS-PROVIDES-CLOCK-GETTIME :LITTLE-ENDIAN)' < crossbuild-runner/pass-1.lisp > Sprints/Sprint2/crossbuild-pass-1.log 2>&1 && ls obj/xbuild/wasm/xc.core"
fi

echo "== level 0"
if tests/wasm/run-level0.sh > Sprints/Sprint2/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' Sprints/Sprint2/level0.log) checks, all modules validate and run"; else bad "level-0 (see Sprints/Sprint2/level0.log)"; cat Sprints/Sprint2/level0.log; fi
check "level-0 covers every module writer section kind" "grep -q 'PASS validate sections.wasm' Sprints/Sprint2/level0.log"
check "level-0 exercised exception handling and tail calls under wasmtime" "grep -q 'PASS run eh.catcher' Sprints/Sprint2/level0.log && grep -q 'PASS run eh.tail' Sprints/Sprint2/level0.log"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
