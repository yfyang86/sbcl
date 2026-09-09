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
# Environment: WASI_SDK or WASISDK_PATH (tools-for-build/wasm-env.sh sets
# the platform default),
# WASM_CORE_SYMBOLS (default obj/xbuild/wasm-core.wasm.symbols, the list
# genesis writes next to the core module; it feeds the linkage table).
set -e
cd "$(dirname "$0")/.."
top=$(pwd)

headers=${1:-}
[ $# -gt 0 ] && shift
if [ -z "$headers" ]; then
    # pass-2 writes genesis-headers; the Sprint 5/6 genesis-only runs -2
    for d in obj/xbuild/wasm/genesis-headers obj/xbuild/wasm/genesis-headers-2; do
        [ -f "$d/sbcl.h" ] && headers=$d && break
    done
fi
[ -n "$WASI_SDK" ] || WASI_SDK=${WASISDK_PATH:-}
if [ -z "$WASI_SDK" ]; then
    for d in "$HOME/bin/wasi-sdk" "$HOME/tools/wasi-sdk" /home/user/tools/wasi-sdk /opt/wasi-sdk; do
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

# The core's list covers the cold core only. Code loaded later (the warm
# sources, user code) resolves foreign names at run time through the same
# table, so after the first link the table is extended with every name the
# Lisp sources (or tools-for-build/wasm-linkage-extra.txt) mention that the
# runtime defines or links (llvm-nm over its objects), and the runtime is
# linked again. See tools-for-build/wasm-linkage-extra.sh.
make_runtime() {
    (cd src/runtime && make CC="$WASI_SDK/bin/clang" AR="$WASI_SDK/bin/llvm-ar" "$@" sbcl.wasm)
}
make_runtime "$@"
extra=$(tools-for-build/wasm-linkage-extra.sh "$symbols")
if [ -n "$extra" ]; then
    n=$(echo "$extra" | wc -l | tr -d ' ')
    echo "linkage table: $n more symbols for code loaded at run time"
    { cat "$symbols"; echo "$extra"; } > obj/xbuild/wasm-linkage.symbols
    tools-for-build/wasm-linkage-table.sh obj/xbuild/wasm-linkage.symbols > src/runtime/wasm-linkage-table.c
    make_runtime "$@"
fi
