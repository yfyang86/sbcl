# Sprint 1 — verify and further study

Tool versions: wasmtime 45.0.0, wasm-tools 1.240.0, wasi-sdk 27 (clang
20.1.8), Node v22.22.2 (V8 12.4), host SBCL 2.4.8, Rust 1.94.1 stable.
Machine: 4 cores, 15 GB, x86-64 Linux.

Each section states the spike's question from
`doc/wasm-port/06-risks-and-spikes.md`, the result, and what it decides.

## S0.1 — Does the tool chain close?

- wasi-sdk 27 compiles C to `wasm32-wasip1`; the hello world reports
  `sizeof(void*)=4` under wasmtime and under the Rust `sbcl-wasm` runner.
- The Rust host (Wasmtime 45 crate, `wasmtime-wasi` preview 1) instantiated
  `runtime.wasm`, grew its exported function table by two slots, instantiated
  `plugin.wasm` against the runtime's memory and table, and the plugin's
  element segment filled the two slots. Calling them through the C
  function `call_slot` (a `call_indirect` through the same table) returned
  42 and 121, and the plugin's store into linear memory was visible to the
  host. One detail matters for the design: the table range must be grown
  *before* instantiation; an element segment cannot grow the table itself.
- `Module::new` latency (Cranelift, 4 cores):

  | Module | Functions | Compile |
  |---|---|---|
  | 503 B | 40 | 1.3 ms |
  | 52 KB | 4,000 | 69 ms |
  | 5.6 MB | 400,000 | 7.1 s |

  Runtime `compile` of one code component (hundreds of bytes to a few
  kilobytes) costs about a millisecond. A cold-core module of tens of
  megabytes costs seconds of Cranelift time at every start under
  wasmtime, so the standalone host must use Wasmtime's precompiled
  modules (`Module::serialize` / `wasmtime compile`), and browsers rely
  on their compiled-code caches. This becomes a Sprint 5 host feature
  rather than a Phase 4 item. `runtime.wasm` (136 KB) compiled in 18 ms.

Decides: runtime `compile` can be implemented as "emit a module, ask the
host to instantiate it against the shared memory and table" (design 2.2).
The C side calls new functions through an ordinary function pointer; no
runtime support beyond the table export is needed. The Rust host in
`wasm/` is the seed of `sbcl-wasm`.

## S0.2 — Exception handling and tail calls in real engines

| Engine | `try_table`/`throw`/rethrow through 1,000 frames | `return_call` 10^7 | `return_call_indirect` 10^7 | Flags |
|---|---|---|---|---|
| Node 22.22 (V8 12.4) | works: catch at frame 500, 5 intermediate handlers rethrew | 17.5 ms | 34.4 ms | none needed |
| wasmtime 45 | works | ok | ok | `-W exceptions=y` required (off by default); tail calls on by default |

Per-unwind cost under V8: an unwind through 50 frames with 10,000
repetitions costs 3.3 microseconds each, so `throw`/`return-from` across
frames is cheaper than the signal-free alternatives.

Decides: design 2.6 stands. Non-local exit uses Wasm exception handling;
the return-flag fallback is not needed for the two primary engines.
Tail calls are usable for the `tail-call` VOPs (design 2.4). The
`sbcl-wasm` host enables exceptions explicitly.

Further study: Safari and Firefox were not measured here (no browser in
this container beyond Chromium); Sprint 14's Playwright job covers them.

## S0.3 — Cost of the dispatch-loop encoding

Node 22 (V8 12.4, TurboFan), best of two runs; wasmtime 45 (Cranelift)
includes about 10 ms of process start per invocation. Results were
identical between the two encodings in every case.

| Kernel | Structured (Node) | Dispatch loop (Node) | Ratio | Structured (wasmtime) | Dispatch loop (wasmtime) |
|---|---|---|---|---|---|
| fib 32 (call-heavy) | 16.9 ms | 28.1 ms | 1.66 | 28 ms | 43 ms |
| tak 24 16 8 | 5.8 ms | 10.8 ms | 1.86 | 14 ms | 20 ms |
| loop 5·10^7, two branches per iteration | 85.4 ms | 169.3 ms | 1.98 | 86 ms | 177 ms |
| byte scan 60 KB × 2000 | 56.4 ms | 251.1 ms | 4.45 | – | – |

Decides: Node 22 (V8 12.4, TurboFan), best of two runs; wasmtime 45 (Cranelift)
includes about 10 ms of process start per invocation. Results were
identical between the two encodings in every case.

| Kernel | Structured (Node) | Dispatch loop (Node) | Ratio | Structured (wasmtime) | Dispatch loop (wasmtime) |
|---|---|---|---|---|---|
| fib 32 (call-heavy) | 16.9 ms | 28.1 ms | 1.66 | 28 ms | 43 ms |
| tak 24 16 8 | 5.8 ms | 10.8 ms | 1.86 | 14 ms | 20 ms |
| loop 5·10^7, two branches per iteration | 85.4 ms | 169.3 ms | 1.98 | 86 ms | 177 ms |
| byte scan 60 KB × 2000 | 56.4 ms | 251.1 ms | 4.45 | – | – |_DECISION

## S0.4 — What breaks when `src/runtime` is compiled to wasm32-wasip1

42 C files (common + gencgc + the wasm arch and OS stubs). After the WASI
os header and two shims (`pseudo-atomic.h` thread-slot case, a `siginfo_t`
shim), 32 compile. The remaining 10 failures are the runtime port list:

| File | Error | Port action (Sprint 5) |
|---|---|---|
| `interrupt.c`, `runtime.c`, `thread.c`, `run-program.c` | `sys/wait.h` not found | gate `run-program.c` out (`#-os-provides-fork`), remove `wait` use from the others under `LISP_FEATURE_WASM` |
| `interr.c`, `print.c` | `setjmp`/`longjmp` unavailable without `-mllvm -wasm-enable-sjlj` | these are LDB paths; build with `--disable-ldb` and gate the remaining uses |
| `backtrace.c` | `dladdr`/`Dl_info` | no dynamic symbol lookup; use the core map for names |
| `os-common.c` | `elf.h` | ELF core-in-executable support; gate under `LISP_FEATURE_ELF` |
| `wrap.c` | `pwd.h` | `getpwnam`/`getpwuid` wrappers; gate for WASI |
| `wasm-linux-os.c` | `sys/cachectl.h` | riscv copy; the real `wasm-wasi-os.c` has no icache flush |

Behind the shims lie the real design items already in `02-design.md`:
`interrupt.h` prototypes are signal-typed (102 `siginfo_t` errors before
the shim) and must be split so that the pending-interrupt bookkeeping
survives without signal handlers; `os_alloc_gc_space`, guard pages and
`zero_range_with_mmap` need the linear-memory implementations from 2.3.
None of the 32 compiling files needed source changes, which confirms the
"port is ~1,500 lines of new C plus feature gates" estimate.

Decides: `:unix` stays as the OS feature base (wasi-libc supplies the
POSIX surface those 32 files use); a `wasi-os.h` replaces `linux-os.h`
(the stub written here is its first version).

## S0.5 — Development loop

`make-config.sh --arch=wasm` accepted the new target; `make-host-1.sh`
built the cross-compiler from the riscv-derived scaffold and genesis pass
1 wrote 32-bit headers with `LISP_FEATURE_WASM` and
`SBCL_TARGET_ARCHITECTURE_STRING "wasm"` (about four minutes on this
machine). `crossbuild-runner` then built the
cross-compiler (`obj/xbuild/wasm/xc.core`) and, once
`tools-for-build/perfecthash` was built so that the perfect-hash
generator ran in record mode, pass-2 cross-compiled all 299 target files
and genesis wrote a 25 MB cold core (`obj/xbuild/wasm.core`) for the
32-bit wasm scaffold. Fifteen new 30-bit perfect-hash journal entries were
merged into `xperfecthash30.lisp-expr`, which is what upstream does when a
configuration is added.

Decides: Sprint 1 and 2 of the plan can iterate on the host alone, as
intended: edit backend, `make-host-1`, validate output. The scaffold's
shared-file edits (`develop.md`) are the exact set of `#+` sites a real
backend must review; each is a one-line feature-list addition.

Further study: `debug-int.lisp:795` selects `ra-save-offset` for riscv
and now wasm; the wasm frame layout (design 2.4) replaces that slot with
the return-point descriptor, so this site changes again in Sprint 3.

## S0.6 — wasm32 or wasm64

memory64: a 5 GiB `i64` memory with a store and load above 4 GiB runs
under wasmtime 45 with default flags and under Node 22 with default
flags. Engine support is no longer the blocker it was assumed to be.

32-bit layout check: `src/compiler/generic/parms.lisp:405-415` defines
`n-linkage-index-bits` (19) and `symbol-linkage-index-pos` only under
`#+64-bit`; the linkage index lives in the symbol header word next to the
32-bit hash, which a 32-bit header word cannot hold. `:linkage-space` on
wasm32 therefore requires object-layout work, which confirms the design
choice to start with fdefn-based calls (2.1). `:soft-card-marks` has no
word-size dependency (`parms.lisp:136-152`).

Decides: keep wasm32 first for the reasons in 2.1 (bounds-check cost,
smaller cores, all engines), but wasm64 is promotable to Phase 3 instead
of Phase 4 if 32-bit paths prove costly; the backend must keep the
riscv-style `#+64-bit` parameterisation from day one.

## S0.7 — GC roots from a thread-struct register area

`gencgc.c` has two root-scanning regimes selected by `GENCGC_IS_PRECISE`:

- x86/x86-64 (`!GENCGC_IS_PRECISE`): `conservative_stack_scan`
  (`gencgc.c:3152`) pins everything the C/Lisp stack and the interrupt
  contexts point to.
- every other target (`GENCGC_IS_PRECISE`, including riscv and arm64):
  the control stack holds only tagged descriptors and is *scavenged*
  precisely by `scavenge_control_stack` (`gc-common.c:2398`, called at
  `gencgc.c:3509`); only the boxed registers of interrupt contexts and
  the call chain's code objects are pinned, by
  `pin_call_chain_and_boxed_registers` (`gencgc.c:3090`), which iterates
  a per-arch `BOXED_REGISTERS` list and calls `pin_exact_root` (plus
  `impart_mark_stickiness` under soft card marks).

For wasm the second regime applies with one substitution: there are no
interrupt contexts, and GC only runs from the allocation slow path, at
which point every live descriptor is either in the register area of the
thread struct or on the control stack. The wasm version of
`pin_call_chain_and_boxed_registers` therefore loops over the
`BOXED_REGISTERS` slots of the thread-struct register file exactly as the
existing loop does over an interrupt context, and pins the code objects
found by walking `OCFP` frames (the `#else` branch at `gencgc.c:3104`
already does this by frame pointer, not by return address). The
non-descriptor register slots are never scanned, which matches the
existing treatment of unboxed registers. `scavenge_control_stack` is
unchanged.

Decides: design 2.4 and 2.8 are consistent with the existing GC with an
estimated change of under 50 lines in `gencgc.c` and a
`BOXED_REGISTERS` definition in `wasm-lispregs.h`. No prototype was
needed; the 42-file compile in S0.4 already covers `gencgc.c`.

Further study: with registers cached in Wasm locals (Sprint 12) the
flush-before-slow-path discipline is what keeps this true; the
compiler-only differential tests (level 1) should include a GC-in-slow-path
case as soon as the mini-runtime has a collector hook.
