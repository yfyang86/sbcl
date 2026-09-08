#!/bin/sh
# S0.4: compile every C file the wasm Config would use with wasi-sdk clang,
# one at a time, collecting errors per file. Uses the genesis headers that
# make-host-1 produced for the wasm scaffold (src/runtime/genesis/).
WASI_SDK=${WASI_SDK:-/home/user/tools/wasi-sdk}
RT=/home/user/sbcl/src/runtime
OUT=$(cd "$(dirname "$0")" && pwd)/out
mkdir -p "$OUT"
cd "$RT"
COMMON="alloc.c backtrace.c breakpoint.c coalesce.c coreparse.c dynbind.c funcall.c gc-common.c globals.c hopscotch.c interr.c interrupt.c largefile.c main.c monitor.c murmur_hash.c os-common.c parse.c perfecthash.c print.c run-program.c runtime.c safepoint.c save.c sc-offset.c search.c sprof.c stringspace.c thread.c time.c validate.c var-io.c vars.c wrap.c arena.c regnames.c gc-unit-tests.c"
ARCH="wasm-arch.c"
OS="wasm-linux-os.c"
GC="fullcgc.c gencgc.c traceroot.c"
CFLAGS="--target=wasm32-wasip1 -O1 -g0 -Wall -Wno-unused -I. -DSBCL_PREFIX=\"/usr/local\" -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID"
summary="$OUT/summary.txt"; : > "$summary"
for f in $COMMON $ARCH $OS $GC; do
  o="$OUT/${f%.c}.o"; log="$OUT/${f%.c}.log"
  if "$WASI_SDK/bin/clang" $CFLAGS -c "$f" -o "$o" > "$log" 2>&1; then
    echo "OK    $f ($(grep -c 'warning:' "$log") warnings)" >> "$summary"
  else
    echo "FAIL  $f ($(grep -c 'error:' "$log") errors)" >> "$summary"
  fi
done
cat "$summary"
echo "--- link attempt (undefined symbols):"
"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -o "$OUT/sbcl.wasm" "$OUT"/*.o -lwasi-emulated-signal -lwasi-emulated-mman -lwasi-emulated-process-clocks -lwasi-emulated-getpid 2>&1 | grep -o "undefined symbol: [a-zA-Z_0-9]*" | sort | uniq -c | sort -rn > "$OUT/undefined.txt"
wc -l < "$OUT/undefined.txt"
