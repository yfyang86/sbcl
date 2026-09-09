#!/bin/sh
# The port's "sbcl binary": runs src/runtime/sbcl.wasm under the host
# (wasm/crates/sbcl-wasm-host) with the given SBCL arguments, so that the
# scripts which run the runtime (run-sbcl.sh, tests/subr.sh,
# make-target-contrib.sh) can use it where they use src/runtime/sbcl.
#   tools-for-build/wasm-sbcl.sh [sbcl-options...]
# The core defaults to output/sbcl.core (--core overrides it);
# SBCL_WASM_RUNTIME overrides the module.
here=$(cd "$(dirname "$0")/.." && pwd)
runtime=${SBCL_WASM_RUNTIME:-$here/src/runtime/sbcl.wasm}
exec "$here/tools-for-build/wasm_run.sh" "$runtime" "$@"
