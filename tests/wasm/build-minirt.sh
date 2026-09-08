#!/bin/sh
# Build the mini-runtime with wasi-sdk. Memory is 18 MiB so that the
# static-space addresses of the real layout are valid.
set -e
WASI_SDK=${WASI_SDK:-/home/user/tools/wasi-sdk}
cd "$(dirname "$0")"
"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -O2 -mexec-model=reactor \
  -Wl,--export-table -Wl,--growable-table -Wl,--export-memory \
  -Wl,--initial-memory=$((20 * 1024 * 1024)) -Wl,--max-memory=$((64 * 1024 * 1024)) \
  -o minirt.wasm minirt.c
wasm-tools validate minirt.wasm
echo "built $(pwd)/minirt.wasm"
