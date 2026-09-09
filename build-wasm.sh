#!/bin/sh
# Build the SBCL WebAssembly port: tool chain, host, Lisp cross build,
# runtime. See WASM-Manual.md.
#
#   ./build-wasm.sh [options] [step ...]
#
# Steps (default: all):
#   toolchain  check wasi-sdk, wasmtime, wasm-tools, a host SBCL and cargo;
#              download the pinned tool-chain releases that are missing
#              (never overwrites an existing installation)
#   host       build the Wasmtime host, wasm/target/release/sbcl-wasm
#   grovel     regenerate the target's groveled C constants
#              (crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp)
#              by running tools-for-build/grovel-headers.c under the host
#   lisp       crossbuild pass-1 (host compiler) and pass-2 (cross-compile
#              the tree, genesis): obj/xbuild/wasm.core, wasm-core.wasm,
#              wasm.map, genesis headers. About 20 minutes.
#   runtime    build src/runtime/sbcl.wasm with wasi-sdk (needs lisp)
#   smoke      sbcl.wasm --version and --help under the host
#   test       level-0 and level-1 test suites (level-1 rebuilds the
#              after-xc core, about 10 minutes)
#   run        run sbcl.wasm with the cold core; arguments after "--" go to
#              the runtime (e.g. run -- --noinform)
#   clean      remove the Lisp build products and the runtime objects
#   env        print the tool-chain settings and exit
#   all        toolchain host lisp runtime grovel smoke
#
# Options:
#   --fast     lisp: skip pass-1/pass-2 when their products exist
#   --no-download  toolchain: only check, never download
#   --jobs N   parallel jobs for the runtime build (default 4)
#
# Platform wrappers set the tool paths first: build-wasm-linux-x86_64.sh,
# build-wasm-darwin-arm64.sh. Run from any directory.
set -u
here=$(cd "$(dirname "$0")" && pwd)
cd "$here"
. tools-for-build/wasm-env.sh

fast=0; download=1; jobs=4; steps=""
while [ $# -gt 0 ]; do
    case "$1" in
        --fast) fast=1 ;;
        --no-download) download=0 ;;
        --jobs) shift; jobs=$1 ;;
        --jobs=*) jobs=${1#--jobs=} ;;
        --) shift; break ;;
        -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "build-wasm.sh: unknown option $1" >&2; exit 2 ;;
        *) steps="$steps $1" ;;
    esac
    shift
done
[ -n "$steps" ] || steps="all"
runargs="$*"

log_dir=obj/wasm-build
mkdir -p "$log_dir"
say() { printf '\033[1m== %s\033[0m\n' "$*"; }
die() { echo "build-wasm.sh: $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

fetch() { # url dest
    say "downloading $1"
    if have curl; then curl -fsSL -o "$2" "$1" || die "download failed: $1"; else wget -q -O "$2" "$1" || die "download failed: $1"; fi
}

step_env() {
    cat <<EOT
system/arch        $WASM_HOST_SYSTEM-$WASM_HOST_ARCH
WASISDK_PATH       $WASISDK_PATH (wasi-sdk $WASISDK_VERSION)
WASMTIME_BIN_PATH  $WASMTIME_BIN_PATH (wasmtime $WASMTIME_VERSION)
WASMTOOLS_BIN_PATH $WASMTOOLS_BIN_PATH (wasm-tools $WASMTOOLS_VERSION)
host sbcl          $(command -v sbcl 2>/dev/null || echo "not found") $(sbcl --version 2>/dev/null | cut -d' ' -f2)
cargo              $(command -v cargo 2>/dev/null || echo "not found")
node (optional)    $(command -v node 2>/dev/null || echo "not found")
EOT
}

step_toolchain() {
    say "tool chain"
    ok=1
    # wasi-sdk
    if [ -x "$WASISDK_PATH/bin/clang" ]; then
        echo "wasi-sdk: $WASISDK_PATH ($(head -1 "$WASISDK_PATH/VERSION" 2>/dev/null))"
    elif [ "$download" = 1 ] && [ -n "$WASISDK_ASSET" ]; then
        parent=$(dirname "$WASISDK_PATH"); mkdir -p "$parent"
        fetch "$WASISDK_URL" "$parent/$WASISDK_ASSET"
        (cd "$parent" && tar xf "$WASISDK_ASSET") || die "cannot unpack wasi-sdk"
        unpacked=$parent/${WASISDK_ASSET%.tar.gz}
        [ -d "$unpacked" ] || die "wasi-sdk unpacked somewhere unexpected (wanted $unpacked)"
        [ -e "$WASISDK_PATH" ] || ln -s "$unpacked" "$WASISDK_PATH"
        rm -f "$parent/$WASISDK_ASSET"
        echo "wasi-sdk: installed at $WASISDK_PATH"
    else
        echo "wasi-sdk: MISSING at $WASISDK_PATH"; ok=0
    fi
    # wasmtime
    if [ -x "$WASMTIME_BIN_PATH/wasmtime" ] || have wasmtime; then
        echo "wasmtime: $(command -v wasmtime) ($(wasmtime --version 2>/dev/null))"
    elif [ "$download" = 1 ] && [ -n "$WASMTIME_ASSET" ]; then
        tmp=$(mktemp -d); fetch "$WASMTIME_URL" "$tmp/$WASMTIME_ASSET"
        (cd "$tmp" && tar xf "$WASMTIME_ASSET") || die "cannot unpack wasmtime"
        mkdir -p "$WASMTIME_BIN_PATH"
        cp "$tmp"/wasmtime-v*/wasmtime "$WASMTIME_BIN_PATH/" && rm -rf "$tmp"
        echo "wasmtime: installed in $WASMTIME_BIN_PATH"
    else
        echo "wasmtime: MISSING in $WASMTIME_BIN_PATH"; ok=0
    fi
    # wasm-tools
    if [ -x "$WASMTOOLS_BIN_PATH/wasm-tools" ] || have wasm-tools; then
        echo "wasm-tools: $(command -v wasm-tools) ($(wasm-tools --version 2>/dev/null))"
    elif [ "$download" = 1 ] && [ -n "$WASMTOOLS_ASSET" ]; then
        tmp=$(mktemp -d); fetch "$WASMTOOLS_URL" "$tmp/$WASMTOOLS_ASSET"
        (cd "$tmp" && tar xf "$WASMTOOLS_ASSET") || die "cannot unpack wasm-tools"
        mkdir -p "$WASMTOOLS_BIN_PATH"
        cp "$tmp"/wasm-tools-*/wasm-tools "$WASMTOOLS_BIN_PATH/" && rm -rf "$tmp"
        echo "wasm-tools: installed in $WASMTOOLS_BIN_PATH"
    else
        echo "wasm-tools: MISSING in $WASMTOOLS_BIN_PATH"; ok=0
    fi
    # host SBCL (the cross-compiler runs in it)
    if have sbcl; then
        echo "host sbcl: $(command -v sbcl) ($(sbcl --version))"
    elif [ "$download" = 1 ] && [ -n "$SBCL_HOST_ASSET" ]; then
        tmp=$(mktemp -d); fetch "$SBCL_HOST_URL" "$tmp/$SBCL_HOST_ASSET"
        (cd "$tmp" && tar xf "$SBCL_HOST_ASSET") || die "cannot unpack the host SBCL"
        prefix=${SBCL_HOST_PREFIX:-$HOME/.local}
        (cd "$tmp"/sbcl-* && INSTALL_ROOT=$prefix sh install.sh > "$here/$log_dir/sbcl-install.log" 2>&1) \
            || die "host SBCL install failed (see $log_dir/sbcl-install.log)"
        rm -rf "$tmp"
        PATH="$prefix/bin:$PATH"; export PATH
        export SBCL_HOME="$prefix/lib/sbcl"
        echo "host sbcl: installed under $prefix (add $prefix/bin to PATH and set SBCL_HOME=$SBCL_HOME)"
    else
        echo "host sbcl: MISSING (Linux: the build can download it; macOS: brew install sbcl)"; ok=0
    fi
    # cargo, for the host
    if have cargo; then
        echo "cargo: $(command -v cargo) ($(cargo --version))"
    else
        echo "cargo: MISSING (install Rust: https://rustup.rs)"; ok=0
    fi
    [ "$ok" = 1 ] || die "tool chain incomplete"
}

step_grovel() {
    say "groveled constants (grovel-headers.c under the host)"
    # needs the genesis headers: run after 'lisp' (or 'runtime')
    tools-for-build/wasm-grovel-headers.sh "$log_dir/groveled.lisp" || die "grovel failed"
    if cmp -s "$log_dir/groveled.lisp" crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp; then
        echo "crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp is up to date"
    else
        cp "$log_dir/groveled.lisp" crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp
        echo "updated crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp:"
        echo "  the constants changed; rebuild the Lisp side (rm obj/xbuild/wasm.core; ./build-wasm.sh --fast lisp runtime)"
    fi
}

step_host() {
    say "host (wasm/crates/sbcl-wasm-host)"
    (cd wasm && cargo build --release -p sbcl-wasm-host --bin sbcl-wasm) > "$log_dir/host.log" 2>&1 \
        || { tail -20 "$log_dir/host.log"; die "host build failed (see $log_dir/host.log)"; }
    echo "built wasm/target/release/sbcl-wasm"
}

# no dynamic loading on this target (doc/wasm-port/02-design.md, 2.9): pass-1 would add :os-provides-dlopen
xc_features="(:UNIX :LINUX :ELF :OS-PROVIDES-CLOCK-GETTIME :LITTLE-ENDIAN (NOT :OS-PROVIDES-DLOPEN))"

# version.lisp-expr is generated (make-config.sh runs generate-version.sh)
# and not in git: the cross-compiler reads it. generate-version.sh needs
# 'git describe' to find an sbcl-* tag, which a clone of the port's
# repository may not have; then the version is the base release plus the
# commit.
ensure_version_file() {
    [ -f version.lisp-expr ] && return 0
    ./generate-version.sh >/dev/null 2>&1 || true
    if [ ! -f version.lisp-expr ]; then
        hash=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
        printf '"2.6.8.wasm-dev.%s"\n' "$hash" > version.lisp-expr
    fi
    echo "version.lisp-expr: $(tail -1 version.lisp-expr)"
}

step_lisp() {
    have sbcl || die "no host sbcl in PATH (run the toolchain step)"
    ensure_version_file
    if [ "$fast" = 1 ] && [ -f obj/xbuild/wasm/xc.core ]; then
        say "pass-1: obj/xbuild/wasm/xc.core present, skipped (--fast)"
    else
        say "pass-1: the cross-compiler (about 4 minutes)"
        rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/xc.core
        sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
             wasm wasm "$xc_features" < crossbuild-runner/pass-1.lisp > "$log_dir/pass-1.log" 2>&1 \
            || { tail -30 "$log_dir/pass-1.log"; die "pass-1 failed (see $log_dir/pass-1.log)"; }
    fi
    if [ "$fast" = 1 ] && [ -f obj/xbuild/wasm.core ] && [ -f obj/xbuild/wasm-core.wasm ] \
       && [ -f obj/xbuild/wasm/genesis-headers/sbcl.h ]; then
        say "pass-2: obj/xbuild/wasm.core present, skipped (--fast)"
    else
        say "pass-2: cross-compile the tree and genesis (about 15 minutes)"
        rm -rf obj/xbuild/wasm/from-xc obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm
        sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
             wasm < crossbuild-runner/pass-2.lisp > "$log_dir/pass-2.log" 2>&1 \
            || { tail -30 "$log_dir/pass-2.log"; die "pass-2 failed (see $log_dir/pass-2.log)"; }
    fi
    ls -la obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm obj/xbuild/wasm.map | awk '{print $5, $9}'
    wasm-tools validate --features all obj/xbuild/wasm-core.wasm && echo "core module validates"
}

step_runtime() {
    say "runtime (src/runtime/sbcl.wasm)"
    [ -f obj/xbuild/wasm-core.wasm.symbols ] || die "no obj/xbuild/wasm-core.wasm.symbols: run the lisp step first"
    tools-for-build/wasm-build-runtime.sh "" -j"$jobs" > "$log_dir/runtime.log" 2>&1 \
        || { grep -E "error" "$log_dir/runtime.log" | head -20; die "runtime build failed (see $log_dir/runtime.log)"; }
    grep -E "warning:" "$log_dir/runtime.log" | head -5
    ls -la src/runtime/sbcl.wasm | awk '{print $5, $9}'
    wasm-tools validate --features all src/runtime/sbcl.wasm && echo "sbcl.wasm validates"
}

step_smoke() {
    say "smoke test"
    [ -x wasm/target/release/sbcl-wasm ] || step_host
    tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --version || die "--version failed"
    tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --help | head -3
}

step_test() {
    say "level-0"
    tests/wasm/run-level0.sh > "$log_dir/level0.log" 2>&1 && echo "level-0: $(grep -c '^PASS' "$log_dir/level0.log") checks" \
        || { tail -5 "$log_dir/level0.log"; die "level-0 failed"; }
    say "level-1 (after-xc core, about 10 minutes)"
    if [ "$fast" = 1 ] && [ -f obj/xbuild/wasm/after-xc.core ]; then
        echo "after-xc.core present, skipped (--fast)"
    else
        rm -rf obj/xbuild/wasm/from-xc obj/xbuild/wasm/after-xc.core
        sbcl --noinform --disable-debugger --no-userinit --no-sysinit \
             --load tests/wasm/make-after-xc.lisp > "$log_dir/after-xc.log" 2>&1 \
            || { tail -20 "$log_dir/after-xc.log"; die "after-xc failed"; }
    fi
    XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > "$log_dir/level1.log" 2>&1 \
        && grep '^level1:' "$log_dir/level1.log" || { tail -5 "$log_dir/level1.log"; die "level-1 failed"; }
}

step_run() {
    [ -x wasm/target/release/sbcl-wasm ] || step_host
    exec tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core obj/xbuild/wasm.core $runargs
}

step_clean() {
    say "clean"
    rm -rf obj/xbuild/wasm obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm obj/xbuild/wasm-core.wasm.symbols obj/xbuild/wasm.map "$log_dir"
    (cd src/runtime && rm -f *.o sbcl.wasm wasm-linkage-table.c)
}

for step in $steps; do
    case "$step" in
        env) step_env ;;
        toolchain) step_toolchain ;;
        host) step_host ;;
        grovel) step_grovel ;;
        lisp) step_lisp ;;
        runtime) step_runtime ;;
        smoke) step_smoke ;;
        test) step_test ;;
        run) step_run ;;
        clean) step_clean ;;
        all) step_toolchain; step_host; step_lisp; step_runtime; step_grovel; step_smoke ;;
        *) die "unknown step $step (see --help)" ;;
    esac
done
