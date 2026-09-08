#!/bin/sh
set -e
WASI_SDK=${WASI_SDK:-/home/user/tools/wasi-sdk}
cd "$(dirname "$0")"
# --export-table: expose __indirect_function_table; --growable-table: let the host grow it
"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -O2 -o runtime.wasm runtime.c \
   -Wl,--export-table -Wl,--growable-table -Wl,--export-memory -mexec-model=reactor -Wl,--export=main
wasm-tools parse plugin.wat -o plugin.wasm
wasm-tools validate runtime.wasm
wasm-tools validate plugin.wasm
echo built
