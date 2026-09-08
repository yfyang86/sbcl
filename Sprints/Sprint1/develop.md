# Sprint 1 — develop

Everything below was built on branch `sprint1` (from `wasm-dev`) and is
reproducible with the commands shown. Tool versions are in `verify.md`.

## Environment set-up (once)

```
mkdir -p /home/user/tools && cd /home/user/tools
curl -sSL -o wasmtime.tar.xz  https://github.com/bytecodealliance/wasmtime/releases/download/v45.0.0/wasmtime-v45.0.0-x86_64-linux.tar.xz
curl -sSL -o wasm-tools.tar.gz https://github.com/bytecodealliance/wasm-tools/releases/download/v1.240.0/wasm-tools-1.240.0-x86_64-linux.tar.gz
curl -sSL -o wasi-sdk.tar.gz  https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-27/wasi-sdk-27.0-x86_64-linux.tar.gz
curl -sSL -o sbcl.tar.bz2     https://github.com/sbcl/sbcl/releases/download/sbcl-1.4.14/sbcl-2.4.8-x86-64-linux-binary.tar.bz2
tar xf wasmtime.tar.xz; tar xf wasm-tools.tar.gz; tar xf wasi-sdk.tar.gz; tar xf sbcl.tar.bz2
ln -s $PWD/wasmtime-v45.0.0-x86_64-linux/wasmtime /usr/local/bin/
ln -s $PWD/wasm-tools-1.240.0-x86_64-linux/wasm-tools /usr/local/bin/
ln -sfn $PWD/wasi-sdk-27.0-x86_64-linux wasi-sdk
(cd sbcl-2.4.8-x86-64-linux && ./install.sh)      # host SBCL, as upstream CI does
```

Node 22 and Rust stable were already present.

## S0.1 — tool chain (`spikes/s01-toolchain/`, `wasm/`)

- `runtime.c`: a stand-in for the C runtime. Exports `memory`,
  `__indirect_function_table` (growable) and `call_slot(slot, arg)`, which
  calls through the table the way `call_into_lisp` will. Built by
  `build.sh` with `wasi-sdk` clang, `--target=wasm32-wasip1`.
- `plugin.wat`: a module "compiled at runtime". Imports the runtime's
  memory and table and an `env.table_base` global, and installs two
  functions with an active element segment at `table_base`.
- `wasm/`: the Rust workspace from `doc/wasm-port/03-toolchain.md`, in
  Phase 0 form: crate `sbcl-wasm-host` with two binaries.
  `sbcl-wasm` is a WASI runner with the engine features the port needs
  (exceptions, tail calls, 64 MB engine stack). `spike-s01` instantiates
  `runtime.wasm`, then `plugin.wasm` against the runtime's memory and
  table, calls the new table slots through `call_slot`, and times
  `Module::new` for synthetic modules of 1 KB, 100 KB and 10 MB generated
  with `wasm-encoder`.

```
Sprints/Sprint1/spikes/s01-toolchain/build.sh
(cd wasm && cargo build --release)
wasm/target/release/spike-s01 Sprints/Sprint1/spikes/s01-toolchain
```

## S0.2 — exception handling and tail calls (`spikes/s02-eh-tailcall/`)

`eh.wat` models the design in `02-design.md` 2.6: one tag `$lisp_unwind`,
1,000 nested frames, every 100th frame has a `try_table` handler that
checks whether it is the unwind target and rethrows otherwise; plus
`return_call` and `return_call_indirect` countdowns of 10^7. `run.mjs`
drives it under Node; the wasmtime CLI drives it with `--invoke`.

```
cd Sprints/Sprint1/spikes/s02-eh-tailcall
wasm-tools parse eh.wat -o eh.wasm && wasm-tools validate --features all eh.wasm
node run.mjs
wasmtime run -W exceptions=y,tail-call=y --invoke unwind_test eh.wasm 1000 500
```

## S0.3 — control-flow encodings (`spikes/s03-control-flow/`)

`structured.wat` and `dispatch.wat` contain the same four kernels (fib,
tak, a tight loop with two branches per iteration, a byte scan) written
with structured control flow and with the dispatch-loop encoding of
`02-design.md` 2.5. `bench.mjs` times both under Node and checks that
results agree; `bench-wasmtime.sh` times them under wasmtime.

```
cd Sprints/Sprint1/spikes/s03-control-flow
wasm-tools parse structured.wat -o structured.wasm; wasm-tools parse dispatch.wat -o dispatch.wasm
node bench.mjs; ./bench-wasmtime.sh
```

## S0.4 — compiling `src/runtime` to wasm32-wasip1 (`spikes/s04-runtime/`)

Needs the genesis headers from S0.5. `compile-all.sh` compiles each C
file the wasm `Config` would use, one at a time, with wasi-sdk clang and
wasi-libc's emulation flags, and records per-file success and the error
lines. Three passes were run:

1. as-is with `target-os.h -> linux-os.h`: every file fails on `ucontext.h`.
2. with `src/runtime/wasi-os.h` (the future `--os=wasi` header, no
   signals or ucontext) as `target-os.h`: 10 of 42 files compile; the
   dominant error is `siginfo_t` from `interrupt.h`.
3. with `LISP_FEATURE_WASM` added to the thread-slot pseudo-atomic case in
   `pseudo-atomic.h` and a signal shim appended to `wasi-os.h`: 32 of 42
   compile. The remaining 10 failures are the real port list
   (`summary-pass2.txt`, `errors-pass2.txt`).

```
Sprints/Sprint1/spikes/s04-runtime/compile-all.sh
```

## S0.5 — the `:wasm` target scaffold

A copy of the riscv backend, renamed, so that the host can build a
cross-compiler and run genesis for a 32-bit `wasm` target. This is
throwaway scaffolding: Sprint 2 replaces every file under
`src/compiler/wasm/` and `src/assembly/wasm/`. What it proves is that
the build system accepts the new target end to end.

```
cp -r src/compiler/riscv src/compiler/wasm
cp -r src/assembly/riscv src/assembly/wasm
cp src/code/riscv-vm.lisp src/code/wasm-vm.lisp
# inside the copies: #+riscv -> #+wasm, :riscv -> :wasm, sb-riscv-asm -> sb-wasm-asm
```

Shared files touched, all mechanically (`riscv` in a feature expression
gains `wasm` beside it): `src/cold/shebang.lisp`, `src/cold/chill.lisp`
(target keyword list), `src/cold/build-order.lisp-expr` (`wasm-vm`),
`src/compiler/generic/{genesis,objdef,parms,vm-fndb,vm-ir2tran}.lisp`,
`src/compiler/{aliencomp,constraint,srctran}.lisp`,
`src/code/{alieneval,cas,debug-int,early-raw-slots,float-trap,irrat,macros,setf-funs,share-vm}.lisp`,
`make-config.sh` (arch case), `build-all-cores.sh` (crossbuild configuration),
`crossbuild-runner/backends/wasm/{features,stuff-groveled-from-headers.lisp}`,
`src/runtime/{Config.wasm-linux,wasm-arch.[ch],wasm-lispregs.h,wasm-linux-os.[ch],wasi-os.h}`,
`src/runtime/pseudo-atomic.h`.

```
echo '"2.6.8.wasm-dev.<sha>"' > version.lisp-expr        # no tags in this fork
sh make-config.sh --arch=wasm --xc-host='sbcl --dynamic-space-size 2GB --lose-on-corruption --disable-ldb --disable-debugger'
sh make-host-1.sh                                       # cross-compiler + genesis pass 1
sh build-all-cores.sh -j1 wasm                          # crossbuild-runner pass-1 and pass-2
```

Note: `--non-interactive` must not be in the host command; make-host-1
feeds the host its forms on stdin and that flag makes SBCL exit first.

## S0.6 — wasm64 probe (`spikes/s06-wasm64/`)

`mem64.wat` declares an `i64` memory of 5 GiB and stores and loads a word
above the 4 GiB line. Run under wasmtime with and without `-W memory64`
and under Node with and without `--experimental-wasm-memory64`.

## S0.7 — GC roots

Analysis of `src/runtime/gencgc.c` and `gc-common.c`; no code. See
`verify.md`.
