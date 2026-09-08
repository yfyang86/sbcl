# 3. Tool chain

## 3.1 Components

| Tool | Role | Version policy |
|---|---|---|
| Host SBCL (x86-64 Linux or macOS arm64) | runs the cross-compiler (`make-host-1`, `make-host-2`, genesis); the same requirement every SBCL build has | current release, pinned in CI like `linux-qemu.yml` does |
| clang + wasi-sdk (wasi-libc, `libclang_rt.builtins-wasm32`) | compiles `src/runtime/` to `wasm32-wasip1` | wasi-sdk 25 or newer; clang 18 is already present in the dev container, wasi-sdk is downloaded by a script |
| Rust stable + `wasm32-wasip1` target | host runner, build tools, test orchestration | pinned `rust-toolchain.toml`; `cargo vendor` for offline CI |
| Wasmtime (Rust crate `wasmtime`, `wasmtime-wasi`) | the standalone engine used by every build and test stage; embedded, not shelled out to, so `sbcl_host` imports are one code base | pinned crate version; requires exception handling and tail calls enabled |
| `wasm-tools` crates (`wasmparser`, `wasm-encoder`, `wasmprinter`) | validate assembler output in unit tests, print modules for debugging, generate the linkage table | pinned |
| Binaryen `wasm-opt` | optional optimization and size reduction of the cold core module | optional, release build only |
| Node 22+ / Chromium (Playwright is preinstalled in the dev container) | browser host tests | latest LTS |
| GNU make, sh | unchanged SBCL build drivers | |

Rust is the main tool chain for everything that is not SBCL itself. The
compiler backend must be Lisp (it runs inside SBCL) and the runtime stays C
(see `02-design.md` 2.11).

## 3.2 Repository layout of new material

```
src/compiler/wasm/            backend: parms, vm, insts, macros, move, arith, call, nlx, ...
                              plus wasm-only files: func-asm.lisp (control-flow lowering),
                              module.lisp (module writer), stackify.lisp (Phase 3)
src/assembly/wasm/            support, assem-rtns, tramps, alloc, arith, array
src/code/wasm-vm.lisp         target-side VM glue
src/runtime/wasm-arch.[ch]    arch interface (arch.h:22-75)
src/runtime/wasm-lispregs.h   register slot offsets
src/runtime/wasm-wasi-os.[ch] OS interface over WASI
src/runtime/Config.wasm-wasi  ASSEM_SRC (none), ARCH_SRC, OS_SRC, GC_SRC, CFLAGS, LINKFLAGS
crossbuild-runner/backends/wasm/{features,wasi-headers.lisp,stuff-groveled-from-headers.lisp}
tools-for-build/wasm_run.sh   runs a target binary under sbcl-wasm, returns its exit code
                              (the analogue of tools-for-build/android_run.sh)
wasm/                         Rust workspace and web host (see below)
tests/wasm/                   compiler-only differential tests and mini-runtime (see 05-testing.md)
.github/workflows/linux-wasm.yml
doc/wasm-port/                these documents
```

Rust workspace `wasm/`:

```
wasm/Cargo.toml                       workspace, pinned toolchain
wasm/crates/sbcl-wasm-host/           `sbcl-wasm` CLI: Wasmtime embedding, WASI, sbcl_host imports,
                                      Ctrl-C and timers, epoch interruption, module instantiation,
                                      stack-size configuration; the process that `run-sbcl.sh`
                                      and tests/subr.sh invoke for --arch=wasm
wasm/crates/sbcl-wasm-tools/          `sbcl-wasm-tools validate|print|linkage-table|inspect-core`
wasm/crates/sbcl-wasm-test/           runs compiler-only differential tests and the mini-runtime
wasm/web/                             TypeScript browser host: worker, WASI shim, sbcl_host,
                                      REPL page, Playwright tests
```

The `sbcl_host` import namespace is the contract between the Lisp/C side
and both hosts. It is specified once in `wasm/HOST-ABI.md` and both hosts
are tested against the same conformance script.

## 3.3 Build flow for `--arch=wasm`

```
./make-config.sh --arch=wasm --os=wasi --xc-host='sbcl ...' \
    --without-sb-thread --without-sb-ldb --with-sb-core-compression=no
./make-host-1.sh                # host: cross-compiler + genesis pass 1 headers
./make-target-1.sh              # wasi-sdk clang builds src/runtime/sbcl.wasm;
                                # grovel-headers runs via tools-for-build/wasm_run.sh
./make-host-2.sh                # host: cross-compile src/code, genesis pass 2:
                                #   output/cold-sbcl.core + output/cold-sbcl.wasm
./make-target-2.sh              # sbcl-wasm src/runtime/sbcl.wasm --core output/cold-sbcl.core
                                #   warm load, save-lisp-and-die -> output/sbcl.core (+ sbcl-core.wasm)
./make-target-contrib.sh        # under sbcl-wasm
```

`make-config.sh` learns `--os=wasi`, `SBCL_ARCH=wasm`, and, when
`SBCL_HOST_LOCATION` style separation is not used, wraps every target
execution in `wasm_run`. `run-sbcl.sh` and `tests/subr.sh` detect the
Wasm build (`src/runtime/sbcl.wasm` exists) and route `run_sbcl` through
`sbcl-wasm`. This is the same shape as the Android and qemu paths, so the
top-level scripts change little.

Two developer loops exist, and the fast one does not need the runtime:

1. **Host-only loop** (Phase 1): `crossbuild-runner` builds the wasm
   cross-compiler and cold core on the host in minutes. Backend work is
   tested by validating emitted modules and by the compiler-only
   differential tests, which execute generated functions under Wasmtime
   with a 200-line mini-runtime instead of the real one.
2. **Full loop** (Phase 2 onward): the build above, then
   `tests/run-tests.sh` under `sbcl-wasm`.

## 3.4 Engine requirements and configuration

The Rust host enables in Wasmtime: exceptions, tail calls, multi-value,
bulk memory, reference types, SIMD; a configurable `max_wasm_stack` (start
at 8 MB); epoch interruption for Ctrl-C and timers; WASI preview 1 with
preopened directories for the build tree; and the `sbcl_host` imports.
Browser: Chromium and Firefox current releases; Safari support is tracked
by the exception-handling spike.

## 3.5 CI

`.github/workflows/linux-wasm.yml`, modelled on `linux-qemu.yml`:

1. Install host SBCL, wasi-sdk, Rust; `cargo build --release -p sbcl-wasm-host`.
2. `crossbuild-runner` job: `build-all-cores.sh wasm` (host only, minutes).
   Add `wasm` to `*all-configurations*` in `build-all-cores.sh` so the
   existing `linux.yml` crossbuild step covers it.
3. Full build job: the flow in 3.3, then `tests/run-tests.sh` under
   Wasmtime (parallel across files with `tests/parallel-exec.sh`), then
   `tests/ansi-tests.sh`.
4. Browser job (nightly): build `wasm/web`, run the Playwright suite in
   Chromium and Firefox.
5. Performance job (nightly): cl-bench and `benchmarks/` under Wasmtime and
   Node, results stored as artifacts and compared with the previous run.
