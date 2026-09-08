#!/bin/sh
# Run a WebAssembly module under the port's host (wasm/crates/sbcl-wasm-host):
#   tools-for-build/wasm_run.sh MODULE.wasm [args...]
# Used for the runtime (src/runtime/sbcl.wasm) and for build-time tools
# such as grovel-headers compiled for wasm32-wasip1. Builds the host on
# first use. SBCL_WASM_HOST overrides the host binary.
set -e
here=$(cd "$(dirname "$0")/.." && pwd)
host=${SBCL_WASM_HOST:-$here/wasm/target/release/sbcl-wasm}
if [ ! -x "$host" ]; then
    (cd "$here/wasm" && cargo build --release -p sbcl-wasm-host --bin sbcl-wasm >&2)
fi
exec "$host" "$@"
