#!/bin/sh
# Build the WebAssembly runtime, src/runtime/sbcl.wasm, with wasi-sdk.
#
# The genesis headers come from a cross build of the :wasm target (see
# Sprints/Sprint5/pass2.sh or genesis-only.sh); this script copies them
# into src/runtime/genesis, points the arch/os header symlinks at the
# wasm files, regenerates the linkage table from the core's required
# symbols, and runs make. Usage:
#
#   tools-for-build/wasm-build-runtime.sh [genesis-header-dir] [make-args...]
#
# Environment: WASI_SDK (default /home/user/tools/wasi-sdk or /opt/wasi-sdk),
# WASM_CORE_SYMBOLS (default obj/xbuild/wasm-core.wasm.symbols, the list
# genesis writes next to the core module; it feeds the linkage table).
set -e
cd "$(dirname "$0")/.."
top=$(pwd)

headers=${1:-obj/xbuild/wasm/genesis-headers-2}
[ $# -gt 0 ] && shift
if [ -z "$WASI_SDK" ]; then
    for d in /home/user/tools/wasi-sdk /opt/wasi-sdk; do
        [ -x "$d/bin/clang" ] && WASI_SDK=$d && break
    done
fi
[ -x "$WASI_SDK/bin/clang" ] || { echo "wasi-sdk not found (set WASI_SDK)" >&2; exit 1; }
[ -f "$headers/sbcl.h" ] || { echo "no genesis headers in $headers" >&2; exit 1; }

mkdir -p output src/runtime/genesis
[ -f output/prefix.def ] || echo "SBCL_PREFIX='/usr/local'" > output/prefix.def
rm -f src/runtime/genesis/*
cp "$headers"/* src/runtime/genesis/

cd src/runtime
ln -sf Config.wasm-wasi Config
ln -sf wasm-arch.h target-arch.h
ln -sf wasm-lispregs.h target-lispregs.h
ln -sf wasm-wasi-os.h target-arch-os.h
ln -sf wasi-os.h target-os.h
cd "$top"

symbols=${WASM_CORE_SYMBOLS:-obj/xbuild/wasm-core.wasm.symbols}
[ -f "$symbols" ] || { echo "no symbol list $symbols" >&2; exit 1; }
tools-for-build/wasm-linkage-table.sh "$symbols" > src/runtime/wasm-linkage-table.c

cd src/runtime
exec make CC="$WASI_SDK/bin/clang" AR="$WASI_SDK/bin/llvm-ar" "$@" sbcl.wasm
