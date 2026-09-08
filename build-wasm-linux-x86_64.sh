#!/bin/sh
# Build the SBCL WebAssembly port on Linux x86-64 (the Sprint 1 layout).
# Tools: wasi-sdk at /home/user/tools/wasi-sdk (or $HOME/tools/wasi-sdk,
# /opt/wasi-sdk), wasmtime and wasm-tools in PATH or $HOME/.wasmtime/bin
# and $HOME/.cargo/bin. Missing tools are downloaded by the toolchain step.
# Override any path in the environment before running. See WASM-Manual.md.
#
#   ./build-wasm-linux-x86_64.sh [build-wasm.sh options and steps]
WASM_HOST_SYSTEM=linux
WASM_HOST_ARCH=x86_64
export WASM_HOST_SYSTEM WASM_HOST_ARCH
exec "$(dirname "$0")/build-wasm.sh" "$@"
