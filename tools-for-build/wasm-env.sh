# Tool-chain environment for the SBCL WebAssembly port. Sourced (not run)
# by build-wasm.sh and the build-wasm-<system>-<arch>.sh wrappers; see
# WASM-Manual.md.
#
# Sets, unless already set in the environment:
#   WASISDK_PATH      wasi-sdk root (bin/clang, share/wasi-sysroot)
#   WASMTIME_BIN_PATH directory holding the wasmtime executable
#   WASMTOOLS_BIN_PATH directory holding wasm-tools
#   BINARYEN_BIN_PATH directory holding wasm-opt (binaryen; optional, the
#                     opt step of build-wasm.sh)
#   WASM_HOST_SYSTEM, WASM_HOST_ARCH  from uname
# then exports WASI_SDK (the name the build scripts use) and puts the two
# bin directories in front of PATH. Pinned versions in WASM_*_VERSION.

WASISDK_VERSION=${WASISDK_VERSION:-27}
WASMTIME_VERSION=${WASMTIME_VERSION:-45.0.0}
WASMTOOLS_VERSION=${WASMTOOLS_VERSION:-1.240.0}
BINARYEN_VERSION=${BINARYEN_VERSION:-123}
SBCL_HOST_VERSION=${SBCL_HOST_VERSION:-2.4.8}

WASM_HOST_SYSTEM=${WASM_HOST_SYSTEM:-$(uname -s | tr 'A-Z' 'a-z')}
WASM_HOST_ARCH=${WASM_HOST_ARCH:-$(uname -m)}
case "$WASM_HOST_ARCH" in
    aarch64|arm64) WASM_HOST_ARCH=arm64 ;;
    x86_64|amd64)  WASM_HOST_ARCH=x86_64 ;;
esac

case "$WASM_HOST_SYSTEM-$WASM_HOST_ARCH" in
    darwin-arm64)
        # macOS (Apple silicon): the layout the port is developed against
        WASMTIME_BIN_PATH=${WASMTIME_BIN_PATH:-$HOME/.wasmtime/bin}
        WASISDK_PATH=${WASISDK_PATH:-$HOME/bin/wasi-sdk}
        WASMTOOLS_BIN_PATH=${WASMTOOLS_BIN_PATH:-$HOME/.cargo/bin}
        BINARYEN_BIN_PATH=${BINARYEN_BIN_PATH:-$HOME/bin/binaryen/bin}
        # release asset names
        WASISDK_ASSET="wasi-sdk-${WASISDK_VERSION}.0-arm64-macos.tar.gz"
        WASMTIME_ASSET="wasmtime-v${WASMTIME_VERSION}-aarch64-macos.tar.xz"
        WASMTOOLS_ASSET="wasm-tools-${WASMTOOLS_VERSION}-aarch64-macos.tar.gz"
        BINARYEN_ASSET="binaryen-version_${BINARYEN_VERSION}-arm64-macos.tar.gz"
        SBCL_HOST_ASSET=""   # no official binary: brew install sbcl
        ;;
    linux-x86_64)
        # Linux: the Sprint 1 layout (/home/user/tools) or a user-level one
        if [ -z "${WASISDK_PATH:-}" ]; then
            for d in /home/user/tools/wasi-sdk "$HOME/tools/wasi-sdk" /opt/wasi-sdk; do
                [ -x "$d/bin/clang" ] && WASISDK_PATH=$d && break
            done
            WASISDK_PATH=${WASISDK_PATH:-$HOME/tools/wasi-sdk}
        fi
        if [ -z "${WASMTIME_BIN_PATH:-}" ]; then
            if command -v wasmtime >/dev/null 2>&1; then
                WASMTIME_BIN_PATH=$(dirname "$(command -v wasmtime)")
            else
                WASMTIME_BIN_PATH=$HOME/.wasmtime/bin
            fi
        fi
        if [ -z "${WASMTOOLS_BIN_PATH:-}" ]; then
            if command -v wasm-tools >/dev/null 2>&1; then
                WASMTOOLS_BIN_PATH=$(dirname "$(command -v wasm-tools)")
            else
                WASMTOOLS_BIN_PATH=$HOME/.cargo/bin
            fi
        fi
        if [ -z "${BINARYEN_BIN_PATH:-}" ]; then
            if command -v wasm-opt >/dev/null 2>&1; then
                BINARYEN_BIN_PATH=$(dirname "$(command -v wasm-opt)")
            else
                for d in /home/user/tools/binaryen "$HOME/tools/binaryen"; do
                    [ -x "$d/bin/wasm-opt" ] && BINARYEN_BIN_PATH=$d/bin && break
                done
                BINARYEN_BIN_PATH=${BINARYEN_BIN_PATH:-$HOME/tools/binaryen/bin}
            fi
        fi
        WASISDK_ASSET="wasi-sdk-${WASISDK_VERSION}.0-x86_64-linux.tar.gz"
        WASMTIME_ASSET="wasmtime-v${WASMTIME_VERSION}-x86_64-linux.tar.xz"
        WASMTOOLS_ASSET="wasm-tools-${WASMTOOLS_VERSION}-x86_64-linux.tar.gz"
        BINARYEN_ASSET="binaryen-version_${BINARYEN_VERSION}-x86_64-linux.tar.gz"
        SBCL_HOST_ASSET="sbcl-${SBCL_HOST_VERSION}-x86-64-linux-binary.tar.bz2"
        ;;
    *)
        echo "wasm-env.sh: no tool-chain layout for $WASM_HOST_SYSTEM-$WASM_HOST_ARCH; set WASISDK_PATH, WASMTIME_BIN_PATH and WASMTOOLS_BIN_PATH yourself" >&2
        WASISDK_PATH=${WASISDK_PATH:-$HOME/bin/wasi-sdk}
        WASMTIME_BIN_PATH=${WASMTIME_BIN_PATH:-$HOME/.wasmtime/bin}
        WASMTOOLS_BIN_PATH=${WASMTOOLS_BIN_PATH:-$HOME/.cargo/bin}
        BINARYEN_BIN_PATH=${BINARYEN_BIN_PATH:-$HOME/bin/binaryen/bin}
        WASISDK_ASSET=""; WASMTIME_ASSET=""; WASMTOOLS_ASSET=""; SBCL_HOST_ASSET=""; BINARYEN_ASSET=""
        ;;
esac

WASISDK_URL="https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASISDK_VERSION}/${WASISDK_ASSET}"
WASMTIME_URL="https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/${WASMTIME_ASSET}"
WASMTOOLS_URL="https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASMTOOLS_VERSION}/${WASMTOOLS_ASSET}"
BINARYEN_URL="https://github.com/WebAssembly/binaryen/releases/download/version_${BINARYEN_VERSION}/${BINARYEN_ASSET}"
# the SBCL project attaches every binary release to its "sbcl-1.4.14"
# GitHub release (the per-version tags carry no assets)
SBCL_HOST_URL="https://github.com/sbcl/sbcl/releases/download/sbcl-1.4.14/${SBCL_HOST_ASSET}"

# a host SBCL the toolchain step installed under $HOME/.local (Linux)
if ! command -v sbcl >/dev/null 2>&1 && [ -x "${SBCL_HOST_PREFIX:-$HOME/.local}/bin/sbcl" ]; then
    PATH="${SBCL_HOST_PREFIX:-$HOME/.local}/bin:$PATH"
    SBCL_HOME=${SBCL_HOME:-${SBCL_HOST_PREFIX:-$HOME/.local}/lib/sbcl}
    export SBCL_HOME
fi

WASI_SDK=$WASISDK_PATH
PATH="$WASMTIME_BIN_PATH:$WASMTOOLS_BIN_PATH:$BINARYEN_BIN_PATH:$PATH"
export WASISDK_PATH WASMTIME_BIN_PATH WASMTOOLS_BIN_PATH BINARYEN_BIN_PATH WASI_SDK PATH
export WASM_HOST_SYSTEM WASM_HOST_ARCH
export WASISDK_VERSION WASMTIME_VERSION WASMTOOLS_VERSION BINARYEN_VERSION SBCL_HOST_VERSION
export WASISDK_ASSET WASMTIME_ASSET WASMTOOLS_ASSET BINARYEN_ASSET SBCL_HOST_ASSET
export WASISDK_URL WASMTIME_URL WASMTOOLS_URL BINARYEN_URL SBCL_HOST_URL
