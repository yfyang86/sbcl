#!/bin/sh
# Build the SBCL WebAssembly port on macOS (Apple silicon). Tool layout:
#   WASMTIME_BIN_PATH="$HOME/.wasmtime/bin"   (wasmtime)
#   WASISDK_PATH="$HOME/bin/wasi-sdk"         (wasi-sdk: bin, include, lib, share)
#   WASMTOOLS_BIN_PATH="$HOME/.cargo/bin"     (wasm-tools)
# If a tool is already there it is used as is; otherwise the toolchain
# step downloads the pinned arm64 macOS release into that place. The host
# SBCL comes from Homebrew (brew install sbcl) and Rust from rustup.
# Override any path in the environment before running. See WASM-Manual.md.
#
#   ./build-wasm-darwin-arm64.sh [build-wasm.sh options and steps]
WASM_HOST_SYSTEM=darwin
WASM_HOST_ARCH=arm64
WASMTIME_BIN_PATH="${WASMTIME_BIN_PATH:-$HOME/.wasmtime/bin}"
WASISDK_PATH="${WASISDK_PATH:-$HOME/bin/wasi-sdk}"
WASMTOOLS_BIN_PATH="${WASMTOOLS_BIN_PATH:-$HOME/.cargo/bin}"
export WASM_HOST_SYSTEM WASM_HOST_ARCH WASMTIME_BIN_PATH WASISDK_PATH WASMTOOLS_BIN_PATH
exec "$(dirname "$0")/build-wasm.sh" "$@"
