# Sprint 6 — development notes

Plan: `doc/wasm-port/04-sprints.md`, "Sprint 5: runtime port"; design:
`doc/wasm-port/02-design.md` 2.2 (modules and the host), 2.7 (interrupts),
2.9 (foreign calls and the linkage table).

## 1. Building the runtime

`tools-for-build/wasm-build-runtime.sh [genesis-header-dir] [make-args]`:

1. copies the genesis headers of the cross build (default
   `obj/xbuild/wasm/genesis-headers-2`) into the git-ignored
   `src/runtime/genesis/`;
2. points the target symlinks at the wasm files: `Config ->
   Config.wasm-wasi`, `target-arch.h -> wasm-arch.h`, `target-lispregs.h ->
   wasm-lispregs.h`, `target-arch-os.h -> wasm-wasi-os.h`, `target-os.h ->
   wasi-os.h`;
3. regenerates `src/runtime/wasm-linkage-table.c` from
   `obj/xbuild/wasm-core.wasm.symbols` with
   `tools-for-build/wasm-linkage-table.sh` (168 symbols: `extern void
   name(void)` or `extern char name[]` plus a name-to-address table and
   `wasm_linkage_lookup`, which is `os_dlsym_default` on this target);
4. runs `make CC=$WASI_SDK/bin/clang sbcl.wasm` in `src/runtime`.

`Config.wasm-wasi` sets `TARGET = sbcl.wasm`, no assembler source, the
four wasm C files as `ARCH_SRC`/`OS_SRC`, the wasi-libc emulation libraries
(signal, mman, process clocks, getpid; the corresponding `-D_WASI_EMULATED_*`
defines go in `CPPFLAGS` so that dependency generation sees them too), and
the link flags: `--export-table --growable-table --export-memory`,
`--max-memory=4 GiB`, an 8 MiB C shadow stack, `--allow-undefined` (the
symbols the runtime does not define become `env.*` imports the host binds
to traps), `--export=alloc --export=alloc_list`. `GC_SRC` is gencgc as
usual. The result: 557 functions, 48 imports (25 WASI, 22 `env`, one
`sbcl_host`), 1.2 MiB with debug info; validates with all features.

The target keeps the crossbuild features `:unix :linux :elf` (so the
common sources take their usual paths) and the wasm-specific code is
selected with `LISP_FEATURE_WASM`, which takes precedence wherever the two
disagree.

### Gates in the common sources

- `thread.c`, `runtime.c`, `wrap.c`: no `<sys/wait.h>`; `wrap.c` also no
  `<pwd.h>`/`<netdb.h>`, no `getpwuid`, no `h_errno`/wait-status helpers;
  `sb_getitimer`/`sb_setitimer` return `ENOSYS`; `sb_mkstemp` has its own
  implementation (wasi-libc has no `mkstemp`); `sb_sigprocmask` moves to
  `wasm-interrupt.c`.
- `interr.c`, `print.c`: no `<setjmp.h>`; the ldb print escape becomes
  `exit(1)`.
- `interrupt.c`, `run-program.c`, `sprof.c`, `monitor.c`: whole files
  compiled out (`#ifndef LISP_FEATURE_WASM` after `genesis/sbcl.h`).
  `wasm-interrupt.c` supplies the symbols the rest of the runtime still
  names (sigsets, `internal_errors_enabled`, `install_handler`,
  `siginfo_code`, `sigprocmask`/`sigaddset`/`sigemptyset`/`sigismember`,
  `allocator_record_backtrace`, the `block_*`/`fake_foreign_function_call`
  family as no-ops or `lose`).
- `runtime.c`: no `thread_sigmask`, `CLOCK_MONOTONIC` instead of the
  Linux-only coarse clock, and `wasm_load_core_module(core)` before
  `create_main_lisp_thread`.
- `os-common.c`: `os_dlsym_default` is `wasm_linkage_lookup`; the ELF core
  search is out; `load_core_bytes` reads the file into the space (no mmap);
  `os_protect` is not compiled (the wasm one is a no-op).
- `os.h`: `ENABLE_PAGE_PROTECTION 0`. `gc-common.c`: `zero_range_with_mmap`
  is `memset`. `pseudo-atomic.h`: on wasm every allocation is pseudo-atomic
  and nothing is ever interrupted (`get_pseudo_atomic_atomic` is 1, the
  others no-ops) — the Lisp side does not maintain the static symbols the
  `#-sb-thread` branch reads, and `alloc()` asserts on them.
- `main.c`: a two-argument `main` for wasm. wasi-libc's start code calls
  `__main_argc_argv` (clang's name for the two-argument main); the usual
  weak three-argument `main` is not found and links as an undefined stub,
  which left a 157-function module without the runtime in it.

### wasm-arch.c

- `lisp_register_area[128]`: the Lisp register file (`wasm-lispregs.h`:
  NARGS, CSP, CFP, OCFP, NFP, NSP, LEXENV, CODE, LIP, CFUNC, A0-A3, L0-L5,
  NL0-NL7, TMP, RA; floats at byte 128, error arguments at 384, the unwind
  target at 448, float modes at 452, the interrupt-pending word at 456).
  Compiled Lisp code reaches it through the module's `thread` global; the
  host is handed its address at instantiation.
- `call_into_lisp(fun, args, nargs)`: finds the entry table index through
  the simple-fun's self slot (walking closures and funcallable instances),
  builds the frame at CSP (or the control stack base for the first call),
  puts the register arguments in A0-A3 and the rest in the callee's frame
  slots, sets NARGS, CFP, CSP, OCFP, RA, LEXENV, CODE and NSP (a 1 MiB
  static number stack), and calls through the table with a C function
  pointer cast (`((int32_t (*)(void))index)()`), then returns A0 (NIL for
  no values). `SBCL_WASM_TRACE_CALLS=1` prints each entry.
- `internal_error` (exported): prints the trap kind, error code, the
  argument descriptors from the register area, the whole register file
  and, when LEXENV holds an fdefn (the callee of a named call), its name;
  then `lose`s. The Lisp error handler is Sprint 7's.
- `pending_interrupt` (exported): a no-op until the Lisp side polls the
  interrupt-pending word.
- `wasm_load_core_module(core)`: reads `<core minus .core>-core.wasm` and
  calls the import `sbcl_host.instantiate(bytes, length, register_area,
  WASM_CORE_TABLE_BASE)`; `WASM_CORE_TABLE_BASE` is 4096, the same as
  `sb-vm::+core-table-base+`, and the host checks it against the module's
  `sbcl.core.table` section.
- `arch_write_linkage_table_entry` stores the C function pointer (a table
  index) or the data address in the linkage cell at
  `ALIEN_LINKAGE_SPACE_START + index*4`.
- Stubs for the contexts, breakpoints, `os_context_error_args_addr` and
  the `fun_end_breakpoint_*` labels the debugger references.

### wasm-wasi-os.c, wasi-mman.c

`os_init`/`os_preinit`, thread init, the context register accessors over a
32-register struct, `sb_GetTID` (one thread, id 1), `_stat`/`_lstat`/
`_fstat`. `os_alloc_gc_space` grows linear memory with
`__builtin_wasm_memory_grow` when a fixed address is asked for and uses
`aligned_alloc` otherwise; `os_invalidate` and `os_protect` are no-ops.

## 2. The host (`wasm/crates/sbcl-wasm-host`, `sbcl-wasm`)

A WASI command runner with the port's engine features and a 64 MiB Wasm
stack, plus:

- `sbcl_host.instantiate`: reads the module bytes out of the runtime's
  memory, checks the `sbcl.core.table` base against the runtime's
  `table_base`, compiles the module, grows the runtime's exported
  `__indirect_function_table` to `base + count`, and instantiates the
  module against the runtime's memory and table, a const `thread` global
  (the register area), a const `table_base` global, one shared
  `lisp_unwind` tag (created on first use, kept for later modules) and the
  runtime's exported `internal_error`, `alloc`, `alloc_list`,
  `pending_interrupt`. Instances are kept for the life of the store.
  `SBCL_WASM_VERBOSE=1` prints the compile and instantiate times.
- `define_unknown_imports_as_traps` for the runtime's `env.*` imports.
- Wasmtime's compilation cache (`Cache::from_file(None)`, the default cache
  directory), keyed on the module bytes and the engine configuration: the
  38 MB core module compiles in 24 s once and loads in 0.8 s afterwards.
- Ctrl-C (`ctrlc` crate): the first press writes 1 into the register
  area's interrupt-pending word and prints a notice; the second terminates
  with a Wasm backtrace. Delivery is by epoch interruption (the handler
  increments the engine epoch; the store's deadline callback does the
  work).
- `SBCL_WASM_TIMEOUT=<seconds>`: a deadline that terminates the run with a
  backtrace, for finding where a run spins.

`tools-for-build/wasm_run.sh MODULE [args]` runs a module under the host
(building it on first use).

## 3. Running the cold core

`tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core obj/xbuild/wasm.core`:
the runtime parses the core (page table and spaces read into linear
memory), links the 168 foreign symbols into the linkage cells (four were
missing on the first run and are now defined: `internal_errors_enabled`
and the three `fun_end_breakpoint_*` labels), instantiates the core module
and calls `!COLD-INIT`. Three bugs surfaced in that order, all outside the
runtime:

1. **Entry numbering in genesis.** `build-wasm-core-module` mapped entry
   *i* of a component's blob to simple-fun *i* of the code object, but the
   dumper numbers `ir2-component-entries` from the last simple-fun down
   (`FOP-FUN-ENTRY (decf fun-index)`; the assembler writes the trailer
   table from the highest entry offset to the lowest). In multi-entry
   components every simple-fun's self slot (and so every fdefn's raw
   address) named the wrong function. Symptom: a zero-argument call to
   `TOPLEVEL-INIT` failing its argument-count check inside another entry
   of the same component. Fix: `for fun-index downfrom (1- (length
   entries))`.
2. **Missing `symbol-hash`/`symbol-name-hash` VOPs.** The target's
   `(defun symbol-name-hash (symbol) (symbol-name-hash symbol))` relies on
   a `:translate` VOP; without one the function tail-calls itself forever
   (a `return_call` loop, so the Wasm stack never grows). Symptom: a run
   spinning at 100% inside `SYMBOL-NAME-HASH` from `%MAKE-FD-STREAM`'s
   component during stream initialization. Fix: the two VOPs in
   `src/compiler/wasm/cell.lisp`, as on the other 32-bit backends (mask to
   a positive fixnum; shift out the three random bits). A scan of the
   self-translating defuns in `src/code` (`(defun f (x) (f x))`) found no
   other unguarded one.
3. **Foreign function SAPs.** `foreign-symbol-sap` produced a constant
   table index `+foreign-table-base+ + n` that nothing filled. Now the
   `:foreign` fixup resolves (like `:foreign-dataref`) to the symbol's
   linkage cell and the VOP loads the cell, which holds the table index
   `os_link_runtime` stored there (a C function pointer is a table index),
   so `call-out`'s `call_indirect` reaches the runtime's C function with
   no host involvement.

4. **CODE after a full call.** The callee's XEP sets CODE to its own code
   object (it derives it from the function object the caller passes in
   CODE) and nothing restored the caller's on return, so every constant
   the caller read afterwards came from the callee's code header: the
   `(!signal-function-cold-init)` after `(!make-cold-stderr-stream)`
   turned into a zero-argument call of whatever word 5 of the callee's
   header held (`FLOOR1`). On register targets the return sequence
   recomputes CODE from the return address; here the caller saves CODE in
   its frame slot `code-save-offset` (reserved since Sprint 4 for the
   debugger) at the start of the call sequence, before CODE is loaded
   with the callee's function, and reloads it right after the call
   (`define-full-call`, `:fixed` and `:unknown` returns; a tail call has
   no frame to come back to). The unwind assembly routine already
   restored CODE from the catch/unwind block for non-local exits. A first
   version saved CODE after the named-call prefix had replaced it and
   restored the callee's function object instead: found by the host's
   register dump at the trap.

Fixes 2 to 4 need a pass-1/pass-2 rebuild (about twenty minutes); fix 1
only genesis (`genesis-map.sh`, three minutes).

## 4. Debugging aids added

- `crossbuild-runner/pass-2.lisp` (and `genesis-map.lisp`) write the
  genesis map `obj/xbuild/wasm.map`: every fdefn's function address and
  name.
- `Sprints/Sprint6/coreindex.py`: maps a core-module function index (as in
  a Wasmtime backtrace), a table index, a heap address or a module code
  offset to the Lisp function, using the map, the core's simple-fun self
  slots and the module's code section.
- The core module's name section names each XEP after its entry and the
  other environments `lambdaN`; Wasmtime backtraces show them.
- `Sprints/Sprint6/wasmfunc.py`: prints one core-module function as text
  with binary offsets (wrapping its body in a throw-away module that
  shares the real type section), marking the instruction at a backtrace
  offset.
- The internal-error report (registers, fdefn name; it ends in an
  `unreachable` trap so that the host prints the Wasm backtrace through
  the Lisp frames), the host's register dump after any trap,
  `SBCL_WASM_TRACE_CALLS`, `SBCL_WASM_TIMEOUT`, `SBCL_WASM_VERBOSE`.

## 5. Not done in this sprint

- grovel-headers and grovel-features under `wasm_run.sh`:
  `tools-for-build/grovel-headers.c` needs gates for the headers WASI lacks
  (`sys/wait.h`, termios, `dlfcn.h`, interval timers, FPE codes) before it
  compiles; the crossbuild keeps using the stand-in
  `crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp`,
  whose type widths are x86-64's. Planned with the OS-layer work.
- `make-config.sh` has no `wasi` case; the runtime is configured by
  `wasm-build-runtime.sh`.
- Timers (`sb_setitimer` reports `ENOSYS`), delivery of the interrupt
  word into Lisp (`pending_interrupt` is a no-op), breakpoints, ldb.
