# SBCL on WebAssembly: investigation plan

This directory holds the investigation and execution plan for a full-scale
WebAssembly (Wasm) port of SBCL: the complete system (compiler, runtime,
garbage collector, PCL, contribs, test suite) running inside a Wasm engine,
in the browser and under a standalone runtime such as Wasmtime.

It is a plan, not an implementation. Nothing here changes how SBCL builds
today. The documents are ordered so that they can be read front to back.

| Document | Contents |
|---|---|
| [01-sbcl-architecture-notes.md](01-sbcl-architecture-notes.md) | How SBCL is put together, as it matters for a new target: build pipeline, cross-compilation, compiler backends, C runtime, tests. With file references into this tree. |
| [02-design.md](02-design.md) | The proposed target design: word size, memory layout, code loading, control flow, calling convention, GC, non-local exit, interrupts, floats, FFI, threads. Alternatives considered and rejected. |
| [03-toolchain.md](03-toolchain.md) | Tool chain: host SBCL cross-compiler, clang/wasi-sdk for the C runtime, Rust + Wasmtime host embedding, wasm-tools, Binaryen, Node/Playwright for browser testing. Repository layout and CI. |
| [04-sprints.md](04-sprints.md) | Phases, sprints, deliverables, exit criteria, sizing. |
| [05-testing.md](05-testing.md) | Test strategy at each level, from Wasm module validation to the ANSI suite, contribs and benchmarks. |
| [06-risks-and-spikes.md](06-risks-and-spikes.md) | Open questions, risks, and the short spikes that must run before Sprint 1 commits to a design. |

## Executive summary

**SBCL has no portable code path.** Every function in an SBCL core is native
machine code produced by one of the architecture backends under
`src/compiler/<arch>/`. The interpreters (`sb-eval`, `sb-fasteval`) are
themselves compiled Lisp. There is no bytecode and no target-independent
fasl. A Wasm port therefore requires a new compiler backend that emits Wasm
bytecode, plus a port of the C runtime. There is no shortcut through an
interpreter.

**The port is feasible, and most of the hard parts already have a
precedent inside the tree.** SBCL has been ported to ten architectures, the
most recent (loongarch64, riscv) in roughly 9,000 lines of backend Lisp and
1,000 lines of runtime glue each. The runtime already supports the
features a Wasm target needs: software card marking instead of `mprotect`
write barriers (`:soft-card-marks`), an indexed linkage table instead of
generated stubs (`:linkage-space`), a relocatable heap, a separate
Lisp-managed control stack (every non-x86 backend), and a
cross-compilation harness that builds a foreign target's cold core on an
x86-64 host (`crossbuild-runner/`).

**Three things have no precedent and drive the design.** Wasm has structured
control flow only (no `goto`), code is not data (no return addresses, no
self-modifying code, no jumping into the middle of a function), and there
are no signals. The design answers these with: a control-flow lowering
pass from SBCL's linear IR2 block order to Wasm `block`/`loop`/`br_table`,
starting with a dispatch-loop encoding and upgrading to a proper
stackifier; Lisp code objects that hold indices into a shared `funcref`
table instead of instruction bytes, with runtime `compile` producing a
fresh Wasm module that the host instantiates; Wasm exception handling for
`throw`/`unwind`; and polling-based interrupts on the existing
`:sb-safepoint` mechanism.

**Recommended target and tool chain.** First target `wasm32`, single
threaded, `gencgc` with soft card marks, `linkage-space`, no immobile space.
The compiler backend is written in Lisp (it must run inside SBCL at runtime
for `compile`). The C runtime stays C, compiled with clang to `wasm32-wasi`
so it is host-agnostic. Rust is the main tool chain for everything outside
SBCL itself: the `sbcl-wasm` host embedding on Wasmtime (module
instantiation for JIT-compiled code, interrupt delivery, I/O, timers), the
build tools (Wasm module validation of assembler output, groveler
replacement, test runner), and the CI harness. A TypeScript browser host is
a thin sibling of the Rust host. `wasm64` and threads are later phases
behind feature flags.

**Sizing.** A working REPL from a cold core is a six-month milestone for a
team of two to three engineers who know SBCL internals. Passing the SBCL
regression suite and ANSI tests with a documented skip list, plus contribs,
plus a browser host, is an eighteen to twenty-four month program. The
sprint plan in `04-sprints.md` is written so that each sprint has a
runnable exit criterion and so that the two greatest unknowns (control-flow
lowering and runtime code loading) are retired in the first quarter.
