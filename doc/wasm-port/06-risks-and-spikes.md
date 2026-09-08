# 6. Risks, open questions, and Phase 0 spikes

## 6.1 Spikes (Phase 0, two to three weeks, before any sprint commits)

Each spike is a small, throwaway experiment with a written result in this
directory (`spikes/S0.n.md`).

| Id | Question | Method | Decides |
|---|---|---|---|
| S0.1 | Does the tool chain close? | wasi-sdk hello world → Wasmtime via the Rust host; instantiate a second module at runtime that adds functions to a shared table; measure `Module::new` latency for 1 KB, 100 KB and 10 MB modules in Wasmtime and V8 | feasibility of runtime `compile`; cold-core module size budget |
| S0.2 | Exception handling and tail calls in real engines | hand-written `.wat`: throw across 1,000 nested frames, through a C frame compiled with wasi-sdk, catch and rethrow; `return_call_indirect` in a 10^7 iteration loop; on Wasmtime, Node 22/24, Chromium, Firefox, Safari | 2.6 (EH versus return-flag unwinding), tail-call use in `tail-call` VOPs |
| S0.3 | Cost of the dispatch-loop encoding | fib, tak, a tight fixnum loop, and a string scan written three ways (structured, dispatch loop, LLVM-stackified) on Wasmtime and V8 | whether the stackifier moves from Phase 3 to Phase 1 |
| S0.4 | What breaks in the runtime | compile `src/runtime` with a stub `wasm-arch.c` and `Config.wasm-wasi` under `--target=wasm32-wasip1`; collect every error and undefined symbol into a checklist | Sprint 5 scope; whether `:unix` is the right OS feature base |
| S0.5 | Development loop | add `:wasm` to `target-platform-keyword`, copy the riscv backend into `src/compiler/wasm/` with renamed instructions, get `crossbuild-runner` pass-1 to build a cross-compiler | Sprint 1 starting point |
| S0.6 | wasm32 or wasm64 | memory64 support and relative performance on the engines in S0.2; `linkage-space` and `soft-card-marks` header layout on 32-bit words | 2.1 word-size decision |
| S0.7 | GC roots | with the S0.4 runtime, prove that `gencgc` can scan a thread-struct register area as a conservative root set on a hand-built heap image (`gc-unit-tests.c` style) | 2.4 register model |

## 6.2 Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Wasm exception handling missing or slow in a target engine | NLX design change | S0.2; the return-flag fallback is designed in (2.6) and only changes codegen |
| Dispatch-loop code too slow for the warm load and test suite to be practical | schedule | S0.3; pull the stackifier forward; `wasm-opt` on the cold core module |
| Runtime `compile` requires the host to instantiate a module per code component; on browser main threads this is asynchronous and size-limited | design | run SBCL in a Web Worker where synchronous `new WebAssembly.Module` is allowed; batch `compile-file` output into one module per file |
| Cold-core module size (all of SBCL as one Wasm module, likely 30–60 MB before optimization) and engine compile time at startup | startup latency | tiered compilation in engines; `wasm-opt -Os`; lazy instantiation of contrib code; measure in S0.1 |
| 32-bit code paths in SBCL are less exercised than 64-bit (x86 and arm are the maintained 32-bit ports) | bugs unrelated to Wasm | run the x86 CI configuration as a reference; S0.6 |
| Conservative root scanning of a 32-bit heap finds more false pointers | memory retention | same as x86; acceptable |
| Debugging a cold boot without LDB, signals or a debugger | Sprint 6 duration | host-side core inspector from the map file; `%primitive print`; Wasmtime's `--debug-info` plus the names section; a deterministic engine makes bugs reproducible |
| `sb-di` and `backtrace` depend on lra semantics in several places | debugger regressions | audit `debug-int.lisp` for `#-(or x86 x86-64)` paths in Sprint 3; the frame layout in 2.4 is fixed early |
| `tests/*.test.sh` spawn many subprocesses; each Wasmtime start plus core load costs hundreds of milliseconds | test wall time | `parallel-exec.sh`; a warm host process that reuses a compiled runtime module |
| Wasm engines may not expose enough native stack for deep Lisp recursion tests | test skips | configurable engine stack; `:skipped-on :wasm` for the deepest recursion tests |
| No `fork`/`exec`, no signals, no `dlopen` under WASI | feature gaps | documented skip list; sockets via WASI preview 2 later; `run-program` unsupported |
| Upstream drift: the backend touches `codegen.lisp`, `dump.lisp`, `load.lisp`, `genesis.lisp`, `debug-int.lisp` | merge cost | keep changes behind `#+wasm`; rebase on upstream monthly; aim to upstream once the regression suite is clean |

## 6.3 Open questions

1. Which OS feature base: `:unix` plus WASI gates, or a fresh `:wasi`
   that reimplements the stream layer? S0.4 answers this.
2. Where should code compiled at runtime go when the host cannot
   instantiate modules (an engine embedded without that import)? Proposed:
   fall back to `sb-fasteval` for `eval` and signal an error for
   `compile`, so an interpreter-only SBCL is still usable.
3. Should the cold core be a separate file or a data segment inside the
   core module? A separate file keeps the existing `--core` interface and
   `save-lisp-and-die` unchanged; an embedded segment gives a single-file
   distribution. Start separate; make embedding a host tool feature.
4. How much of `sb-simd` maps onto Wasm `v128`? Later phase.
5. Threads: wait for the shared-everything threads proposal, or use
   `wasi-threads` / Web Workers with shared memory now? Phase 4 decision.
