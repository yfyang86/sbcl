#!/bin/sh
# Regenerate crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp
# for the WebAssembly target: compile tools-for-build/grovel-headers.c for
# wasm32-wasip1 with wasi-sdk and run it under the port's host. The
# genesis headers of an earlier build supply the LISP_FEATURE_* macros;
# without them a minimal stand-in with the crossbuild features is used.
#   tools-for-build/wasm-grovel-headers.sh [output-file]
set -e
cd "$(dirname "$0")/.."
. tools-for-build/wasm-env.sh
out=${1:-crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
if [ -f src/runtime/genesis/sbcl.h ]; then
    inc=src/runtime
else
    mkdir -p "$tmp/genesis"
    for f in WASM UNIX LINUX ELF GENERATIONAL GENCGC LITTLE_ENDIAN OS_PROVIDES_CLOCK_GETTIME OS_PROVIDES_DLOPEN SB_UNICODE; do
        echo "#define LISP_FEATURE_$f 1"
    done > "$tmp/genesis/sbcl.h"
    inc=$tmp
fi
"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -O1 \
    -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID \
    -I"$inc" -Isrc/runtime -o "$tmp/grovel-headers.wasm" tools-for-build/grovel-headers.c \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid
tools-for-build/wasm_run.sh "$tmp/grovel-headers.wasm" > "$tmp/out.lisp"
mv "$tmp/out.lisp" "$out"
echo "wrote $out"
