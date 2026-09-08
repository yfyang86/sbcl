# 4. Phases and sprints

Sprints are two weeks. Sizing assumes two to three engineers who know SBCL
internals (one on the backend, one on the runtime and hosts, a third
floating to tests and tools from Phase 2). Every sprint ends with something
that runs; the exit criterion is the definition of done.

| Phase | Sprints | Goal | Calendar |
|---|---|---|---|
| 0 Spikes | – | retire the design unknowns (`06-risks-and-spikes.md`) | weeks 1–3 |
| 1 Cross-compiler | 1–4 | host builds a wasm cold core and core module; generated code runs under a mini-runtime | months 1–3 |
| 2 Runtime and boot | 5–8 | runtime compiles to Wasm, cold core boots, GC works, warm load produces `sbcl.core`, regression suite runs to completion | months 3–7 |
| 3 Conformance and performance | 9–14 | regression suite and ANSI suite clean with a documented skip list; stackifier and register caching; callbacks and contribs; browser host; CI | months 7–13 |
| 4 Full scale | 15+ | threads, wasm64, SIMD, dynamic linking, mark-region GC, distribution, upstreaming | months 13–24 |

## Phase 1: cross-compiler and assembler

**Sprint 1: target definition and assembler.**
Add `:wasm` to `src/cold/shebang.lisp` and `chill.lisp`; `make-config.sh`
arch and OS cases; `crossbuild-runner/backends/wasm/features`;
`src/compiler/wasm/parms.lisp` (word size, space layout, trap numbers,
`+backend-fasl-file-implementation+ :wasm32`); `vm.lisp` (thread-struct
register file, storage bases and classes, fixup kinds); `insts.lisp`: LEB128
emitters, numeric, memory, local/global, call and control instructions,
branch pseudo-instructions carrying labels; `src/compiler/wasm/module.lisp`
module writer (types, imports, functions, table, element segments, code,
data, names section). `src/cold/shared.lisp` compatibility table entries.
Exit: `crossbuild-runner` pass-1 builds the wasm cross-compiler; genesis
pass 1 writes headers; the assembler unit tests (level 0 in
`05-testing.md`) pass, including validation of every emitted module by
`wasm-tools`.

**Sprint 2: function assembler and simple VOPs.**
Dispatch-loop control-flow lowering (2.5, encoding 1); `macros.lisp`
(`load-reg`/`store-reg`, `loadw`/`storew`, pseudo-atomic, error traps as
calls to a runtime import); `move.lisp`, `arith.lisp` (fixnum and word
arithmetic, shifts, comparisons, bignum digit ops), `pred.lisp`,
`type-vops.lisp`, `cell.lisp`, `memory.lisp`, `system.lisp`, `char.lisp`,
`sap.lisp`, `show.lisp`. The mini-runtime and the compiler-only
differential test rig (level 1).
Exit: fifty differential tests covering the VOPs above pass under Wasmtime,
comparing results with the host SBCL.

**Sprint 3: calls, frames, allocation, floats, NLX.**
`call.lisp` (frames, XEP, argument parsing, full/local/known calls, single
and multiple value return, tail calls), `values.lisp`, `alloc.lisp`
(inline allocation, slow-path flush and call), `array.lisp`, `float.lisp`
(`f32`/`f64` VOPs, conversions, complex), `nlx.lisp` on `try_table`/`throw`,
`debug.lisp`, `c-call.lisp`; `src/assembly/wasm/` routines
(`return-multiple`, `tail-call-variable`, `throw`, `unwind`, undefined
function trampoline); frame layout changes in `debug-int.lisp` behind
`#+wasm`.
Exit: `make-host-2` cross-compiles all of `src/code` and `src/pcl` with no
undefined VOPs (`output/cold-vop-usage.txt` is the checklist); differential
tests for calls, multiple values, catch/throw, unwind-protect,
dynamic-extent, float arithmetic pass.

**Sprint 4: genesis, fasls and the core module.**
Genesis assigns table indices, emits `cold-sbcl.wasm` with all functions
and the element segment, writes indices into simple-fun headers, records
required foreign symbols; `dump.lisp`/`load.lisp` changes for per-component
modules and patchable fixups; `sbcl-wasm-tools linkage-table` generates the
runtime's symbol table from genesis output.
Exit: `crossbuild-runner` pass-2 produces a wasm cold core and a core
module that validates; pass-1 and pass-2 headers are identical; the core
module loads (not runs) in Wasmtime and V8, and its size and compile time
are recorded against the S0.1 budget.

## Phase 2: runtime and boot

**Sprint 5: runtime port.**
`Config.wasm-wasi`, `wasm-arch.c`, `wasm-lispregs.h`, `wasm-wasi-os.c`;
`os_alloc_gc_space` over linear memory; explicit stack limits; signal code
compiled out; `os_link_runtime` over the generated table;
`call_into_lisp`/`call_into_c`/`funcall0..3` as C over `call_indirect`;
exported `alloc`, `alloc_list`, error and trap entry points; `--disable-ldb`.
`sbcl-wasm` host v0.1 with WASI, `sbcl_host.instantiate`, Ctrl-C, timers.
`tools-for-build/wasm_run.sh`; `grovel-headers` and `grovel-features.sh`
run under it.
Exit: `src/runtime/sbcl.wasm --version` and `--help` work; `coreparse`
loads `cold-sbcl.core`, the core module instantiates against the runtime's
memory and table, and `call_into_lisp` reaches the cold-init entry
function (which may then fail).

**Sprint 6: cold init.**
Drive `!cold-init` (`src/code/cold-init.lisp`) to the REPL: `%primitive
print`, static functions, `sb-impl::!cold-init` package and stream setup,
the first `eval`, `sb-fasteval` off. The host-side core inspector reads
the map file and memory snapshots; Wasmtime's deterministic execution and
`--debug-info` are the debugger. This is historically the hardest
fortnight of any port; budget two sprints.
Exit: `sbcl-wasm src/runtime/sbcl.wasm --core output/cold-sbcl.core --eval '(print (+ 1 2))'` prints 3.

**Sprint 7: garbage collector and warm load.**
`gencgc` with the thread-struct register area as a root set; card marks;
pinning; `(gc :full t)`; allocation stress; `save-lisp-and-die` through
WASI; `make-target-2.sh` warm load (PCL and the rest of `src/cold/warm.lisp`
compiled by the target itself, which is the first heavy use of runtime
`compile` and module instantiation).
Exit: `output/sbcl.core` is produced; the saved core restarts and reaches
the REPL; `tests/gc-smoketest.pure.lisp` and `coreparse.pure.lisp` pass.

**Sprint 8: self-hosting and the first baseline.**
`compile-file` and `load` of fasls; `disassemble`; pure-Lisp contribs
(`asdf`, `sb-rt`, `sb-md5`, `sb-cltl2`, `sb-rotate-byte`, `sb-aclrepl`,
`sb-executable`, `sb-queue`); `tests/subr.sh` and `run-sbcl.sh` routing
through `sbcl-wasm`; `parallel-exec.sh` under Wasmtime.
Exit: `tests/run-tests.sh` runs to completion and produces the first
baseline report (`doc/wasm-port/baselines/sprint-8.txt`) listing every
failing test; `tests/ansi-tests.sh` runs to completion.

## Phase 3: conformance and performance

**Sprint 9–10: triage and fix.**
Classify every baseline failure: backend bug (fix), runtime bug (fix),
unsupported by design (`:skipped-on :wasm` with a one-line reason),
floating-point trap semantics (`:no-float-traps`), timing or depth
(`:broken-on :wasm` with an issue). Add the `#+wasm` expected-failure list
to `tests/ansi-tests.sh`.
Exit: zero unexpected failures in both suites; the skip list is under 150
`with-test` forms and every entry has a reason; CI job `linux-wasm.yml`
runs both suites on every push to `wasm-dev`.

**Sprint 11: stackifier.**
`src/compiler/wasm/stackify.lisp` (2.5, encoding 2) with the dispatch
loop as the irreducible fallback; loop back-edge interrupt polls; `wasm-opt`
integration for the cold core.
Exit: both test suites still clean; cl-bench geometric mean improves by
the factor S0.3 predicted; no function falls back to dispatch except the
irreducible ones, counted in the build log.

**Sprint 12: register caching and calling convention.**
Cache registers in Wasm locals between flush points; pass the first four
arguments as parameters and return `A0` as a result; `return_call_indirect`
for tail calls; measure.
Exit: suites clean; compute-bound cl-bench results within 3x of native
arm64 SBCL under V8 and Wasmtime (record the actual numbers in
`baselines/`).

**Sprint 13: FFI and system contribs.**
Alien callbacks as compiled Wasm functions (`:alien-callbacks`);
`sb-grovel` running its groveler under `wasm_run`; `sb-posix` on the WASI
subset with a documented unsupported list; `sb-introspect`, `sb-cover`,
`sb-sprof` on host-timer sampling, `sb-concurrency` single-threaded parts;
`tests/callback.impure.lisp`, `tests/sb-posix.impure.lisp` gated where
needed.
Exit: `make-target-contrib.sh` builds everything not in
`SBCL_CONTRIB_BLOCKLIST` (sockets, simd, capstone, gmp, mpfr, perf are
blocked); contrib tests pass.

**Sprint 14: browser host.**
`wasm/web`: Web Worker running the runtime and core, WASI shim, `sbcl_host`
implementation, synchronous module instantiation in the worker, a REPL
page, `sb-js` contrib skeleton (`js_call`). Playwright suite: boot, REPL
round trip, `compile` of a function, a subset of pure tests executed in
the worker.
Exit: the REPL page runs in Chromium and Firefox; the Playwright suite is
in the nightly CI; startup time and core module size are recorded.

## Phase 4: full scale

Ordered by value; each is a sprint pair with the same exit discipline.

1. **Distribution**: single-file bundles (runtime module, core module,
   core) produced by `sbcl-wasm-tools bundle`; `save-lisp-and-die :executable t`
   mapped onto it; core compression (zstd compiles to Wasm).
2. **wasm64**: flip `:64-bit`, memory64 in both hosts, `mark-region-gc`
   becomes available; keep wasm32 as the default until engines are equal.
3. **Threads**: `:sb-thread` with `:sb-safepoint` polls for stop-the-world,
   Wasm atomics and `memory.atomic.wait`/`notify` for mutexes and futexes,
   Web Workers and `wasi-threads` for thread creation, per-instance
   `$thread` global; `tests/threads*.lisp` come off the skip list.
4. **SIMD**: `v128` mapping for `sb-simd-pack`, then `sb-simd` for Wasm.
5. **Dynamic linking**: `load-shared-object` of Wasm side modules;
   `sb-bsd-sockets` over WASI preview 2 sockets.
6. **Debugger and tooling**: source-map style names section, DWARF for the
   runtime, Chrome DevTools integration for backtraces.
7. **Upstreaming**: rebase, split into reviewable series (target
   definition, backend, runtime, tests, CI), submit.

## Effort summary

| Phase | Engineer-months | Notes |
|---|---|---|
| 0 | 1 | two people, three weeks |
| 1 | 5 | backend is the critical path; runtime engineer starts S0.4 follow-up in parallel |
| 2 | 7 | cold init is the schedule risk; budget slack there |
| 3 | 10 | triage is parallel across people; performance sprints are one person |
| 4 | 12+ | open ended |

A working REPL from the cold core (end of Sprint 6) is expected at about
month five; a clean regression suite (Sprint 10) at about month nine; the
browser host (Sprint 14) at about month thirteen.
