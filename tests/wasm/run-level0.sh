#!/bin/sh
# Level-0 tests for the WebAssembly backend (doc/wasm-port/05-testing.md).
# Runs the assembler and module-writer tests inside the cross-compiler
# image, validates every module it writes with wasm-tools, and executes
# the exported functions under wasmtime against the expected results.
# Usage: tests/wasm/run-level0.sh   (from the repository root)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
XC=${XC_CORE:-$ROOT/obj/xbuild/wasm/xc.core}
OUT=${LEVEL0_OUT:-$ROOT/obj/wasm-level0}
SBCL=${SBCL:-sbcl}
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0
$SBCL --core "$XC" --noinform --disable-debugger --no-userinit --no-sysinit \
      --load "$ROOT/tests/wasm/level0/assembler.lisp" \
      --eval "(sb-wasm-asm::run-level0 \"$OUT\")" > "$OUT/lisp.log" 2>&1
code=$?
grep "^FAIL\|level0 lisp checks" "$OUT/lisp.log"
[ $code -eq 0 ] || { echo "FAIL lisp-side checks (see $OUT/lisp.log)"; fail=1; }
for w in "$OUT"/*.wasm; do
  if wasm-tools validate --features all "$w" 2> "$OUT/validate.err"; then
    echo "PASS validate $(basename "$w")"
  else
    echo "FAIL validate $(basename "$w"): $(cat "$OUT/validate.err")"; fail=1
  fi
done
while read -r module fn rest; do
  args=${rest%%=>*}; want=${rest##*=> }
  got=$(wasmtime run -W exceptions=y,tail-call=y --invoke "$fn" "$OUT/$module.wasm" $args 2>/dev/null)
  if [ "$got" = "$want" ]; then echo "PASS run $module.$fn($args) = $want"
  else echo "FAIL run $module.$fn($args): got '$got' want '$want'"; fail=1; fi
done < "$OUT/expected.txt"
wasm-tools print "$OUT/sections.wasm" | grep -q '(func $seven_plus_three' && echo "PASS name section" || { echo "FAIL name section"; fail=1; }
[ $fail -eq 0 ] && echo "level0: all passed"
exit $fail
