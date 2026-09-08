#!/bin/sh
# Times each benchmark under wasmtime (includes ~10ms startup per invocation;
# fill+scan is run inside a tiny wrapper module to keep it comparable).
for m in structured dispatch; do
  echo "== $m"
  for call in "fib 32" "tak 24 16 8" "loop 50000000"; do
    set -- $call; fn=$1; shift
    s=$(date +%s%N); r=$(wasmtime run --invoke $fn $m.wasm "$@" 2>/dev/null); e=$(date +%s%N)
    echo "$fn $*: result=$r $(( (e-s)/1000000 )) ms"
  done
done
