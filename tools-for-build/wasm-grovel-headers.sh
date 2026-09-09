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
# grovel-headers.c includes os.h, whose runtime headers need the constants
# genesis writes (upstream compiles it in make-target-1, after genesis):
# take them from the runtime tree if the runtime was built, else from the
# pass-2 products. Without either, the checked-in file stands.
if [ -f src/runtime/genesis/sbcl.h ]; then
    inc=src/runtime
elif [ -f obj/xbuild/wasm/genesis-headers/sbcl.h ]; then
    mkdir -p "$tmp/genesis"
    cp obj/xbuild/wasm/genesis-headers/*.h "$tmp/genesis/"
    inc=$tmp
else
    echo "wasm-grovel-headers.sh: no genesis headers yet (src/runtime/genesis or" >&2
    echo "  obj/xbuild/wasm/genesis-headers); run this after './build-wasm.sh lisp'." >&2
    echo "  The checked-in $out is used until then." >&2
    exit 2
fi
"$WASI_SDK/bin/clang" --target=wasm32-wasip1 -O1 \
    -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID \
    -I"$inc" -Isrc/runtime -o "$tmp/grovel-headers.wasm" tools-for-build/grovel-headers.c \
    -lwasi-emulated-signal -lwasi-emulated-process-clocks -lwasi-emulated-getpid
tools-for-build/wasm_run.sh "$tmp/grovel-headers.wasm" > "$tmp/out.lisp"
mv "$tmp/out.lisp" "$out"
echo "wrote $out"
