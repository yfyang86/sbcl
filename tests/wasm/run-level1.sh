#!/bin/sh
# Level-1 differential tests (doc/wasm-port/05-testing.md, 5.4): compile
# the cases with the wasm cross-compiler, run them under wasmtime against
# the mini-runtime, compare with the host Lisp's results.
# Usage: tests/wasm/run-level1.sh [cases.lisp]   (from the repository root)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
XC=${XC_CORE:-$ROOT/obj/xbuild/wasm/xc.core}
OUT=${LEVEL1_OUT:-$ROOT/obj/wasm-level1}
CASES=${1:-$ROOT/tests/wasm/diff/cases.lisp}
SBCL=${SBCL:-sbcl}
DRIVER=$ROOT/wasm/target/release/sbcl-wasm-test
rm -rf "$OUT"; mkdir -p "$OUT"
[ -f "$ROOT/tests/wasm/minirt.wasm" ] || "$ROOT/tests/wasm/build-minirt.sh" > /dev/null
preload=""
for f in ${LEVEL1_PRELOAD:-}; do preload="$preload --load $f"; done
$SBCL --core "$XC" --noinform --disable-debugger --no-userinit --no-sysinit $preload \
      --load "$ROOT/tests/wasm/diff/run-diff.lisp" \
      --eval "(sb-wasm-asm::run-diff \"$CASES\" \"$OUT\")" > "$OUT/lisp.log" 2>&1
code=$?
grep "^diff:" "$OUT/lisp.log"
if [ $code -ne 0 ]; then
  echo "FAIL compiling the cases (see $OUT/lisp.log):"
  grep -a -m1 -B2 -A6 "Unhandled\|not implemented" "$OUT/lisp.log" | head -20
  exit 1
fi
grep "^#" "$OUT/cases.txt"
for w in "$OUT"/*.wasm; do
  wasm-tools validate --features all "$w" 2> "$OUT/validate.err" || { echo "FAIL validate $(basename "$w"): $(cat "$OUT/validate.err")"; exit 1; }
done
"$DRIVER" "$ROOT/tests/wasm/minirt.wasm" "$OUT/cases.txt"
