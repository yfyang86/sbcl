# 2. Target design

This is the proposed design for the `wasm` target. Each section states the
decision, the reasoning, and the precedent in the existing tree. Decisions
marked **(spike)** depend on a measurement listed in
`06-risks-and-spikes.md` and may be revised after Phase 0.

## 2.1 Feature set and naming

| Item | Decision |
|---|---|
| Architecture keyword | `:wasm`, with `:wasm32` / `:wasm64` for the address width, mirroring how riscv uses `:64-bit` to split rv32/rv64 |
| OS keyword | `:wasi` for the standalone runtime; `:unix` is kept because the fd-stream layer (`src/code/unix.lisp`, `fd-stream.lisp`) maps directly onto WASI preview 1 (`read`, `write`, `open`, `fstat`, `lseek`, `poll_oneoff`). Missing syscalls (`fork`, `execve`, `kill`, `sigaction`, `mmap`, `dlopen`, sockets) are gated individually. Object-format feature: a new `:wasm-binary` satisfies the "execute object file format" rule in `src/cold/shared.lisp:388` |
| Word size, first target | `wasm32`: 32-bit words, 30-bit fixnums (`n-fixnum-tag-bits` 2 as on x86 and arm). Reason: universal engine support, cheaper bounds checks, 4 GB is enough for the whole test suite. `wasm64` (memory64, part of Wasm 3.0) follows behind `:64-bit` once engines are proven **(spike)** |
| GC | `:gencgc` with `:soft-card-marks`, `:use-cons-region`; no `:immobile-space` (x86-64 only, needs fixed executable pages); `:mark-region-gc` deferred to wasm64 |
| Threads | `#-sb-thread` first; `:sb-thread` with `:sb-safepoint` in Phase 4 |
| Linkage | alien linkage table as a data table (entry size 4, contents = function table index or data address), `#-os-provides-dlopen`; Lisp `:linkage-space` deferred, fdefn-based calls first as on riscv |
| Other | `:compare-and-swap-vops`, `:alien-callbacks` (Phase 3), `:unwind-to-frame-and-call-vop`, `:no-float-traps`-style float handling, `:relocatable-heap` unnecessary (see 2.3) |

Wasm feature level: **Wasm 3.0** (2025): multi-value, bulk memory, reference
types, tail calls (`return_call_indirect`), exception handling
(`try_table`/`throw`/`exnref`), extended-const, SIMD, memory64,
multi-memory. Everything except exception handling and tail calls has
been in every engine for years. Engine support for those two is the first
spike.

## 2.2 Object model

Unchanged. Tagged pointers into a single linear memory, the same lowtags
and widetags as every other 32-bit target (`generic/early-objdef.lisp`),
the same primitive objects (`generic/objdef.lisp`), the same core file
format. This keeps the GC, genesis, `save-lisp-and-die`, `sb-di`,
`sb-introspect`, `room`, `sap`s and `with-pinned-objects` working as they
do today.

The one changed object is the **code component**. Today it embeds
instruction bytes and simple-fun headers, and a simple-fun's entry point
is an address inside the component. In Wasm, code is not data. The code
component keeps its shape (header, boxed constants, debug info, simple-fun
headers), but the unboxed area holds no instructions. Each simple-fun's
entry point becomes an **index into a shared `funcref` table**. The Wasm
bytecode for the component lives in a Wasm module owned by the engine, not
in the Lisp heap:

- For the cold core, genesis emits one module, `sbcl-core.wasm`,
  containing every function of every code component, and assigns their
  table indices (function index i is table slot i). The core file records
  the indices inside the simple-fun headers exactly where the entry
  address used to be.
- For code compiled at runtime (`compile`, `load` of a fasl), the compiler
  produces a small standalone module: it imports the linear memory, the
  function table, the thread global and the runtime routines, and its
  active element segment places its functions at a table base allocated by
  Lisp (`table.grow` or a free list of recycled ranges). Lisp calls the
  host import `sbcl_host.instantiate(ptr, len)`; the host runs
  `WebAssembly.instantiate` / `wasmtime::Module::new` and the element
  segment populates the table. When the GC frees a code component, its
  table range is nulled and returned to the free list.
- Fasls therefore contain a Wasm module per code component
  (`dump-code-object`, `src/compiler/dump.lisp:1200`) plus the usual
  fixups, and `load` instantiates it. Absolute-address fixups that must be
  patched into bytecode use fixed-width five-byte LEB128 immediates so they
  can be patched in place before instantiation. Most constants are reached
  through the code object's boxed area, as on riscv, and need no fixups at
  all.

Precedent: `:immobile-code` on x86-64 already decouples "where code lives"
from the dynamic space; `fdefn-raw-addr` already indirects every full call
through a slot that the backend defines. The table index is a different
kind of address, not a different mechanism.

## 2.3 Memory layout

One linear memory. The C runtime, compiled with wasi-libc, owns the low
region (data segment and the C shadow stack, typically the first 1–2 MB).
The Lisp spaces are laid out by `gc-space-setup`
(`src/compiler/generic/parms.lisp:56`) at fixed offsets above that, for
example read-only space at 16 MB, static space after it, dynamic space at
256 MB. The runtime grows the memory to the configured dynamic-space size
at startup with `memory.grow`; there is no `mmap`, no reservation without
commit, and no guard pages. Because the runtime owns the whole address
space, the layout can be fixed at genesis time and `relocate_heap`
(`coreparse.c:577`) is never needed. It stays available for a browser host
that cannot grant the default size.

Per-thread areas (thread struct, control stack, binding stack, alien
stack, TLS) are allocated by the runtime as today (`thread.c`), but the
guard pages become explicit limits: the control-stack check happens in
the frame-allocation VOPs against a limit word in the thread struct, the
binding-stack check in `bind`, the alien-stack check in `alloc-alien-stack-space`.
The `undefined_alien_address` guard (`validate.c:59`) becomes an
unmapped-looking sentinel that the runtime checks in `os_link_runtime`.

Card marks: the `gc_card_mark` byte array is an ordinary allocation in
linear memory; the store-barrier VOP is the arm64 soft-card-marks VOP with
Wasm loads and stores.

Freed pages are zeroed with `memset` (`zero_range_with_mmap` in
`gc-common.c:2922` is bypassed). Memory never shrinks; `memory.grow` is
monotonic. This is a known cost of the platform.

## 2.4 Registers, frames and the calling convention

**Registers are slots in the thread struct.** `vm.lisp` defines a finite
`registers` storage base of 32 word slots and a `float-registers` base of
32 double slots, both living in a fixed area of the thread struct
addressed from one Wasm global `$thread`. `descriptor-reg`, `any-reg`,
`signed-reg`, `unsigned-reg`, `single-reg`, `double-reg` and the other
storage classes required by `generic/primtype.lisp` map onto these
slots, and `control-stack` / `non-descriptor-stack` are the Lisp stacks in
linear memory. Every VOP reads and writes registers through two macros,
`load-reg` and `store-reg`, that expand to `i32.load`/`i32.store` at a
constant offset from `$thread`.

Reasons:

1. The register allocator (`pack.lisp`) and every VOP idiom keep working
   unchanged. The backend looks like riscv with an unusual instruction
   set.
2. The garbage collector sees all registers. `gencgc` already scans saved
   registers in interrupt contexts conservatively; here it scans the
   register area of the thread struct. No precise stack maps are needed.
3. Optimization is a local change. A later sprint caches registers in Wasm
   locals between safepoints and writes them back before any runtime call
   or poll, using the liveness already computed by `life.lisp`. Values
   live across calls are spilled to the stack by `pack` today (`save-p`),
   so the only additional flush points are allocation slow paths and
   interrupt polls, exactly where the arm64 `alloc-tramp` saves all
   registers today. `load-reg`/`store-reg` are the seam.

**Frames** are riscv frames: `allocate-frame` bumps CSP, `CFP`, `OCFP`,
`NFP` are saved in the frame, arguments beyond the register args are
passed on the control stack, `sb-di` walks frames by `OCFP`. The one
change is the return address. There is no `lra`. The `lra-save-offset`
slot holds instead a *return-point descriptor*: a fixnum call-site index
within the caller's code component, and the frame gains a slot for the
caller's code object. `compute-code-from-ra` becomes a slot read.
`sb-di` (`src/code/debug-int.lisp`) has an `#-(or x86 x86-64)` path for
lra-based frames; the wasm path is a small variant of it.

**Every Lisp function has one Wasm signature**: `[] -> [i32]`. Arguments,
argument count, the function object (`lexenv`) and the code object are
passed in registers; the result `i32` is 0 for a single value in `A0` and
1 for multiple values (count in `NARGS`, values in `A0..A3` and on the
stack). This replaces the "return to lra+4 for single value" trick. Full
calls are `call_indirect` through the fdefn's raw-address slot (a table
index); known local calls within one component are direct `call`; tail
calls are `return_call_indirect`. Later optimization passes the first
four arguments as Wasm parameters and returns `A0` as a result.

`call_into_lisp` from C (`funcall.c`, `assem-rtns.lisp:255` on riscv)
becomes a C function that fills the register slots and does an indirect
call; `call_into_c` fills C arguments from registers and does
`call_indirect` with the C signature.

**Recursion depth.** Wasm's own call stack is invisible and finite. The
Lisp control stack in linear memory is checked explicitly (2.3). The
host configures the engine stack large enough that the Lisp limit trips
first in normal use; an engine stack overflow is a trap that the host
reports as fatal, like a C stack overflow in a foreign call today.

## 2.5 Control flow lowering

SBCL's codegen (`codegen.lisp:262-313`) emits IR2 blocks in the linear
order chosen by `control.lisp`, with a label per block and branch VOPs
that target labels. Wasm functions are trees of `block`, `loop`, `if`,
with `br`, `br_if` and `br_table` to enclosing labels only.

The backend keeps the label model at the VOP level and adds a
**function-assembler** stage between the byte-level assembler and the
module writer. Branch instructions in `insts.lisp` (`jump`, `branch-if`,
`branch-table`) are pseudo-instructions carrying labels. When a function
is finalized, the function assembler rewrites the linear stream into
structured form. Two encodings, delivered in order:

1. **Dispatch loop** (Sprint 2). The body is
   `loop $L (block $Bn ... (block $B1 (block $B0 br_table[$pc])) arm0) arm1 ... armn`.
   Each IR2 block is an arm. Fall-through into the physically next block
   is free because arm k ends where arm k+1 begins, which matches the
   order `control.lisp` produced. A taken branch sets the local `$pc` and
   does `br $L`. Correct for any control-flow graph, including the
   irreducible ones `tagbody`/`go` can create. Costs a `br_table` per taken
   branch and hides loop structure from the engine.
2. **Stackifier** (Phase 3 performance sprint). A pass over the IR2 block
   graph computes dominators and loop nesting (the compiler already has
   `dfo.lisp` and `loop.lisp`) and emits nested `block`/`loop` with direct
   `br`/`br_if`, the same algorithm as LLVM's WebAssembly CFGStackify.
   Irreducible regions fall back to a local dispatch loop. This is where
   the engine's loop optimizations come back.

For the cold core module, Binaryen's `wasm-opt` can additionally
restructure and optimize offline. It is not available to runtime
`compile` inside the browser, so the Lisp-side stackifier is required.

## 2.6 Non-local exit

`throw`, `return-from` and `go` across function boundaries, and
`unwind-protect`, use **Wasm exception handling**. One tag,
`$lisp_unwind`, carries no payload; the target unwind block is in the
thread struct as today. The `unwind` routine (riscv:
`assem-rtns.lisp:163`) locates the target catch or unwind block through
the chain on the control stack, sets the target, and executes `throw`.
Every function that contains an NLX entry (a `catch`, an
`unwind-protect` cleanup, a `block` that is returned from non-locally, a
`tagbody` targeted by a `go` from a closure) wraps its body in
`try_table (catch $lisp_unwind $handler)`. The handler compares the
target block to its own frame: if the block belongs to this frame it
restores `CSP`/`CFP` from the block and jumps to the NLX entry label
through the dispatcher; otherwise it rethrows. Functions with no NLX entry
need no `try_table`; the engine unwinds them. Unwinding through C frames
(`call_into_c`, callbacks) is the same as today's behaviour of jumping
past C frames: the C runtime holds no cleanup state across calls into Lisp.
`call_into_lisp` catches a `$lisp_unwind` that escapes the outermost Lisp
frame and reports it as the "unwind to unknown frame" error.

Fallback if an engine lacks exception handling **(spike)**: every call
site checks an `unwinding` flag after return and returns immediately if it
is set. Slower and more code, but purely a codegen change behind the same
`unwind` routine.

## 2.7 Interrupts, timers, signals

There are no signals. The runtime's `interrupt.c` is compiled out except
for the pending-interrupt bookkeeping. Delivery is by polling:

- The host sets a per-thread `pending_interrupt` word in linear memory
  (from a Ctrl-C handler in the Rust host, a `postMessage` in the browser,
  or a Wasmtime epoch deadline). Lisp checks it at function entry
  (`xep-allocate-frame`), at loop back-edges (the stackifier knows them;
  the dispatch loop checks at the loop head), and when leaving
  pseudo-atomic, which is where riscv already checks the
  pseudo-atomic-interrupted bit.
- Timers (`sb-ext:schedule-timer`, `with-timeout`, `sleep`) are host
  timers that set the same word. `sleep` and blocking reads use WASI
  `poll_oneoff` under Wasmtime; in the browser SBCL runs in a Web Worker
  where `Atomics.wait` may block.
- `sb-sprof` samples at polls driven by a host timer, which is
  statistical profiling at safepoints only.
- Floating point traps do not exist in Wasm. `(setf floating-point-modes)`
  accepts and ignores trap masks, results are IEEE with round-to-nearest,
  and tests use the existing `:no-float-traps` gate that arm and riscv
  already rely on.
- Breakpoints by code patching (`breakpoint.c`, `arch_install_breakpoint`)
  are impossible in immutable code. `trace` defaults to encapsulation and
  works; breakpoint-based tracing and `fun-end-breakpoint` are
  unsupported. `step` is implemented by the existing software
  `step-instrument` VOPs and works.
- Stop-the-world for threads (Phase 4) reuses `:sb-safepoint` with the
  same poll word instead of an mprotected page.

## 2.8 Garbage collection

`gencgc.c`, single threaded, soft card marks, no page protection
(`ENABLE_PAGE_PROTECTION 0`). Roots: static space, the thread-struct
register area (scanned conservatively like an interrupt context), the
control stack (scanned conservatively as on every gencgc target), the
binding stack, and pinned objects. Allocation is inline bump allocation
against the thread's allocation region with a slow path that flushes
registers and calls the exported C `alloc`/`alloc_list` through the alien
linkage table, exactly the riscv structure minus the trampoline. Because
GC can only run inside that slow path, and every live Lisp value is in the
register area or on the control stack at that point, no stack maps are
needed and the GC is unchanged.

`save-lisp-and-die` writes the core through WASI files under Wasmtime; in
the browser the host receives the bytes. An "executable" core is the
runtime module plus the core module plus the core file bundled by the
host tool, not an ELF concatenation.

## 2.9 Foreign function interface

- **Calling C.** The runtime module exports every function SBCL links
  against. `os_link_runtime` (`os-common.c:196`) resolves names from a
  static `{name, kind, index-or-address}` table generated at build time by
  a Rust tool from the required-symbols list that genesis already produces,
  instead of `dlsym`. Alien linkage table entries are data words:
  a function entry holds a table index, a data entry holds an address.
  `alien-funcall` emits `call_indirect (type $sig)` where `$sig` is
  derived from the alien function type; SBCL knows the C signature at
  compile time, so each generated module declares the type entries it
  needs. C function pointers in Wasm are table indices already (clang's
  `__indirect_function_table`), so `(alien (* (function ...)))` works
  without special cases. Varargs use clang's Wasm convention (a pointer to
  an argument buffer), which SBCL's limited varargs support can follow.
- **Callbacks.** Because the compiler can emit a Wasm function with any
  signature, `alien-callback` compiles a real Wasm function with the C
  signature that marshals into `enter-alien-callback`, and returns its
  table index. This is simpler than every native platform, which has to
  synthesize executable trampolines. Phase 3.
- **`load-shared-object`.** Not in Phase 1–3 (`#-os-provides-dlopen`).
  Later options: Wasm dynamic linking of side modules (the Emscripten
  `dlopen` ABI) or the component model.
- **Host interop.** A single import namespace `sbcl_host` implemented
  identically by the Rust host and the browser host: `instantiate`,
  `write_console`, `set_timer`, `now`, `random`, `exit`, plus browser-only
  `js_call` for a later `sb-js` contrib.

## 2.10 Disassembler, debugger, tools

`disassemble` needs a Wasm bytecode decoder in `target-insts.lisp`. The
existing disassembler framework (`disassem.lisp`) models fixed-width
fields; the Wasm backend instead supplies a hand-written decoder (about
600 lines) that prints the function's bytecode with labels and the
call-site index annotations that `sb-di` uses. `backtrace.c` gets a Wasm
variant that walks frames by `OCFP` and prints code object names from the
core map. LDB (`monitor.c`) is disabled; its role in early bring-up is
taken by a host-side core inspector (Rust) that reads the map file and
linear memory snapshot.

## 2.11 Toolchain boundary: what is written in what

| Component | Language | Why |
|---|---|---|
| Backend (`src/compiler/wasm/`, `src/assembly/wasm/`, `src/code/wasm-vm.lisp`), function assembler, stackifier, module writer, disassembler | Lisp | must run inside SBCL for `compile` at runtime; it is the SBCL compiler |
| C runtime (`src/runtime/`), `wasm-arch.c`, `wasm-wasi-os.c` | C, clang `--target=wasm32-wasip1` | 57k lines of proven GC and core code; the port is ~1,500 lines of new C plus feature gates |
| `sbcl-wasm` host runner (Wasmtime embedding), `sbcl_host` imports, core inspector, linkage table generator, module validator for tests, test orchestration | Rust | the requested main tool chain; Wasmtime, wasmparser, wasm-encoder are first-class Rust crates |
| Browser host, WASI shim, REPL page, Playwright tests | TypeScript | runs in the browser |
| Build orchestration | shell + make, as today | `make-config.sh --arch=wasm --os=wasi`, `wasm_run` wrapper |

## 2.12 Alternatives considered and rejected

- **WasmGC object model.** Would replace tagged pointers with engine-managed
  structs: a rewrite of the object model, GC, genesis, every VOP, `sap`s,
  pinning, `save-lisp-and-die` and the runtime. It is a different Lisp
  implementation that shares SBCL's front end. Rejected for a full-scale
  SBCL; worth a research spike later for browser interop.
- **Bytecode backend plus interpreter** (the CLISP/ECL model). Faster to a
  first boot and needs no runtime instantiation, but 10–50x slower and
  entirely throwaway once real code generation exists. The dispatch-loop
  encoding in 2.5 gives the same simplicity with engine-compiled code.
- **Emscripten as the primary toolchain.** Provides pthreads, exceptions,
  `dlopen` emulation and JS glue, but ties the runtime to its JS
  environment and is awkward under Wasmtime. Kept as a fallback for
  browser threading in Phase 4.
- **Rewriting the runtime in Rust.** No benefit proportional to the risk;
  every new component outside the runtime is Rust instead.
- **Binary translation of native SBCL output** (an x86-64 emulator in
  Wasm). Not a port.
