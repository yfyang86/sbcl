# 1. SBCL architecture notes for the Wasm port

These notes record what was learned from the tree at the start of the
project. They are selective: only the parts of SBCL that a new target has to
touch or understand are covered. File paths are relative to the repository
root; line numbers are for the tree as of the `wasm-dev` branch point
(SBCL 2.6.8 development).

## 1.1 What SBCL is

SBCL is a native-code Common Lisp implementation. The compiler ("Python",
under `src/compiler/`) compiles every function to machine code; there is no
bytecode tier. The runtime (`src/runtime/`, about 57,000 lines of C plus
per-architecture assembly) provides the garbage collector, core file
loading and saving, the OS and signal interface, threads, and the foreign
function interface. The Lisp side of the system (`src/code/`, about
135,000 lines; `src/pcl/`, about 24,000 lines for CLOS) is compiled by the
same compiler.

Sizes that matter for planning:

| Component | Lines | Notes |
|---|---|---|
| `src/compiler/*.lisp` (target independent) | ~100,000 | IR1, IR2, register allocation, assembler, fasl dumper |
| `src/compiler/generic/` | 13,100 | object layouts, primitive types, genesis |
| One backend, `src/compiler/riscv/` | 9,070 | 305 VOPs; the model for a new port |
| `src/compiler/x86-64/` | 29,100 | 630 VOPs; the most optimized backend |
| `src/assembly/riscv/` | 640 | assembly routines written in the Lisp assembler |
| `src/runtime/` C | 57,000 | of which per-arch glue is ~350 lines for riscv |
| `src/code/` | 135,000 | the Lisp library; 25 files carry per-arch conditionals |
| `tests/` | ~5,300 `with-test` forms | 143 pure, 173 impure, 39 impure-cload, 7 pure-cload, 41 shell |

Supported targets today: `arm arm64 loongarch64 mips ppc ppc64 riscv sparc
x86 x86-64` (the list is `target-platform-keyword` in
`src/cold/shebang.lisp:27`, duplicated in `src/cold/chill.lisp:32`).
Supported OSes are detected in `make-config.sh:296-336`.

## 1.2 The build pipeline

SBCL is always cross-compiled, even for a native build: a host Lisp runs
the SBCL compiler with the target's `sb-vm` parameters loaded and emits a
cold core, which the C runtime then boots. `make.sh` runs these stages in
order:

| Stage | Driver | Runs on | Produces |
|---|---|---|---|
| config | `make-config.sh` | build machine | `local-target-features.lisp-expr`, `output/build-config`, symlinks `src/runtime/{Config,target-arch.h,target-arch-os.h,target-os.h,target-lispregs.h}` |
| host-1 | `make-host-1.sh` → `make-host-1.lisp` | host Lisp | cross-compiler fasls in `obj/from-host/`; genesis pass 1 writes `src/runtime/genesis/*.h` (headers only) |
| target-1 | `make-target-1.sh` | target | C runtime `src/runtime/sbcl`; runs `tools-for-build/grovel-headers` on the target to produce `output/stuff-groveled-from-headers.lisp` |
| host-2 | `make-host-2.sh` → `make-host-2.lisp` | host Lisp | cross-compiles all target sources to `obj/from-xc/` via `src/cold/compile-cold-sbcl.lisp` |
| genesis-2 | `make-genesis-2.sh` | host Lisp | `output/cold-sbcl.core`, `output/cold-sbcl.map`; fails the build if pass-1 and pass-2 headers differ |
| target-2 | `make-target-2.sh` | target | warm load (`src/cold/warm.lisp`: PCL, the rest of the library, compiled by the target itself), then `save-lisp-and-die` → `output/sbcl.core` |
| contribs | `make-target-contrib.sh` | target | `obj/sbcl-home/contrib/*.fasl`, compiled by the target |

Consequences for Wasm:

- Stages target-1, target-2 and contribs execute target code. For Wasm they
  run under a Wasm engine. The precedents are `linux-qemu.yml` (qemu-user)
  and `tools-for-build/android_run.sh` (adb). A `wasm_run` wrapper plays
  the same role.
- The two-pass genesis means the runtime's constants (`sbcl.h`, object
  layouts, space addresses) come entirely from `src/compiler/<arch>/parms.lisp`
  and `vm.lisp`. Getting these two files right is the first job of a port.
- Features are computed by `src/cold/shared.lisp:270-360` from
  `src/cold/base-target-features.lisp-expr`, the per-arch mandatory list in
  `crossbuild-runner/backends/<arch>/features` (read by
  `make-config.sh:822` even for native builds), and OS additions in
  `make-config.sh:562-712`. The compatibility table at
  `src/cold/shared.lisp:374-418` must learn about `:wasm` (notably the rule
  `(not (or elf mach-o win32))` → "No execute object file format feature").
- `src/cold/build-order.lisp-expr` lists every source file; `{arch}` in a
  stem is replaced by the target keyword (`shared.lisp:502-513`). About 35
  stems are per-arch, plus five under `src/assembly/{arch}/`.

### crossbuild-runner

`crossbuild-runner/` builds a cross-compiler (`pass-1.lisp`) and a cold core
(`pass-2.lisp`) for a foreign target on an x86-64 host without a C
toolchain and without running any target code. It substitutes a checked-in
`crossbuild-runner/backends/<arch>/*-headers.lisp` for the groveler output.
`build-all-cores.sh` generates its Makefile and CI runs it for all ten
backends. This is the harness the Wasm backend uses from day one: it lets
the backend be developed and unit-tested on the host long before a Wasm
runtime can boot a core.

## 1.3 The compiler

Pipeline (`src/compiler/main.lisp:574-660`, `%compile-component`):

1. IR1: `ir1tran*.lisp`, `ir1opt.lisp`, `constraint.lisp`, `locall.lisp`,
   `envanal.lisp`. Target independent. Type inference, inlining, local call
   conversion, tail-merging of self calls into loops.
2. `gtn-analyze` (`gtn.lisp`), `ltn-analyze` (`ltn.lisp`, VOP template
   selection), `control-analyze` (`control.lisp`, chooses the linear block
   emission order), `stack-analyze` (`stack.lisp`, unknown-values stack
   discipline), `ir2-convert` (`ir2tran.lisp`), `ir2-optimize`
   (`ir2opt.lisp`), `select-representations` (`represent.lisp`),
   `lifetime-analyze` (`life.lisp`), `pack` (`pack.lisp`,
   `pack-iterative.lisp`: graph-coloring register allocation), then
   `generate-code` (`codegen.lisp:244`).
3. `codegen.lisp:262-313` walks IR2 blocks in the linear order, emits a
   label per block through the per-arch `emit-block-header`, and funcalls
   each VOP generator into the assembler (`assem.lisp`). The assembler has
   code, data and "elsewhere" sections, labels, back-patches and choosers
   for variable-length instructions (`assem.lisp:988-1032`), and
   `define-instruction` at `assem.lisp:1892`.
4. `dump.lisp:1200` dumps assembled bytes plus fixups into the fasl;
   `generic/genesis.lisp` cold-loads fasls into a simulated heap to build
   the core.

A backend supplies (riscv as the reference, `src/compiler/riscv/`):

| File | Lines | VOPs | Role |
|---|---|---|---|
| `parms.lisp` | 113 | | word size, page size, space addresses, trap numbers, fasl implementation tag |
| `vm.lisp` | 290 | | registers, storage bases and classes, fixup kinds |
| `insts.lisp` | 1458 | | assembler (`define-instruction`) |
| `target-insts.lisp` | 260 | | disassembler printers, target only |
| `macros.lisp` | 781 | 16 | `loadw`/`storew`, pseudo-atomic, error traps, allocation |
| `call.lisp` | 1158 | 25 | full/local/known call, XEP, return, tail call, `emit-block-header` |
| `nlx.lisp` | 262 | 15 | catch/unwind blocks |
| `alloc.lisp`, `arith.lisp`, `move.lisp`, `values.lisp`, `memory.lisp`, `cell.lisp`, `c-call.lisp`, `system.lisp`, `char.lisp`, `float.lisp`, `array.lisp`, `subprim.lisp`, `pred.lisp`, `sap.lisp`, `type-vops.lisp`, `debug.lisp`, `show.lisp` | 5,000 | 250 | everything else |

VOP counts per backend: x86-64 630, arm64 530, ppc 364, ppc64 352, sparc
343, riscv 305, loongarch64 301, arm 298, mips 297. The floor for a
working backend is about 300 VOPs. `generic/primtype.lisp` names the
storage classes every backend must provide (`descriptor-reg`, `any-reg`,
`signed-reg`, `unsigned-reg`, `single-reg`, `double-reg`, `*-stack`,
`catch-block`, `unwind-block`, ...).

Plus `src/assembly/<arch>/` routines written in the Lisp assembler:
`return-multiple`, `tail-call-variable`, `throw`, `unwind`,
`call-into-lisp`, `call-into-c`, `do-pending-interrupt`
(`src/assembly/riscv/assem-rtns.lisp`), trampolines for undefined
functions and allocation (`tramps.lisp`), `alloc-tls-index` (`alloc.lisp`).
On riscv and loongarch64 nearly everything is in Lisp; the C-side
`riscv-assem.S` is 53 lines. That is the model to follow.

Plus `src/code/<arch>-vm.lisp` (74 lines for riscv): context register
access, `internal-error-args`, floating point mode access.

Assumptions in the pipeline that Wasm breaks:

- Code is a linear byte stream with labels; branch VOPs
  (`riscv/pred.lisp`) take a label, `control.lisp` and
  `ir2opt.lisp:279` assume fall-through to the physically next block.
  Wasm has `block`/`loop`/`if`/`br`/`br_if`/`br_table` only.
- Non-local exit jumps to a saved code address (`nlx.lisp`, `unwind` in
  `assem-rtns.lisp`). Wasm cannot jump into a function.
- Return addresses (`lra` objects, `ra-tn`) are code addresses stored in
  the control stack frame and used by the debugger to identify the frame's
  code. Wasm has no addressable return addresses.
- The register allocator assumes a finite register file with spills to a
  stack in memory; Wasm has unlimited locals but they are invisible to the
  garbage collector.
- The assembler's disassembler side (`disassem.lisp`,
  `target-disassem.lisp`) models fixed-width instruction fields; Wasm is
  LEB128 variable-length.

Interpreters: `src/code/full-eval.lisp` (sb-eval) and `src/interpreter/`
(sb-fasteval, 5,045 lines) are complete evaluators, but they are compiled
Lisp and need a compiled core. They let a port defer runtime `compile`
(the JIT path) but not the backend itself.

## 1.4 The C runtime

`src/runtime/` groups (lines): core loading `coreparse.c` 1958, `save.c`
946; GC `gencgc.c` 4976, `gc-common.c` 3324, `pmrgc.c`/`mark-region.c`
3242 (64-bit only), `immobile-space.c` 2129 (x86-64 only), `traceroot.c`,
`hopscotch.c`, `fullcgc.c`; OS interface `os-common.c` 766, `validate.c`
155, per-OS `linux-os.c` 341, `bsd-os.c`, `win32-os.c` 2009; signals
`interrupt.c` 2144, `safepoint.c` 1121, `stop-the-world.c` 505; threads
`thread.c` 906; FFI `alloc.c` 833, `funcall.c` 156; misc `runtime.c` 845,
`monitor.c` 1620 (LDB), `print.c`, `backtrace.c`, `wrap.c`,
`run-program.c`.

Per-arch runtime files a port adds (riscv sizes): `riscv-arch.c` 185,
`riscv-arch.h` 4, `riscv-lispregs.h` 57, `riscv-linux-os.c` 97,
`riscv-assem.S` 53, `Config.riscv-linux` 30. The required interface is in
`arch.h:22-75` (`arch_init`, `arch_skip_instruction`, `arch_get_bad_addr`,
pseudo-atomic accessors, breakpoint hooks, `arch_write_linkage_table_entry`,
`funcall0..3`). `GNUmakefile:50` includes `Config` and `:39` includes the
genesis-generated `Makefile.features`, so `Config.<arch>-<os>` can branch on
`LISP_FEATURE_*`.

Runtime facilities relevant to Wasm, with their current status:

| Concern | Current mechanism | Alternative already in tree |
|---|---|---|
| Write barrier | `mprotect` + SIGSEGV | `:soft-card-marks` byte array (x86-64, arm64, ppc64), `gencgc.c:4282` forbids mprotect under it; `os.h:27-40` `ENABLE_PAGE_PROTECTION 0` |
| Foreign symbol linkage | generated code stubs at `ALIEN_LINKAGE_SPACE_START` (`arm64-arch.c:378`) | `:linkage-space` plain word table (`coreparse.c:742`, `gc-common.c:3251`); `os_link_runtime` (`os-common.c:196`) resolves names through `dlsym`, gated by `:os-provides-dlopen` |
| Stop-the-world / interrupts | `SIGUSR2`, `SIGURG`, `SIGALRM`, `SIGINT`, `SIGPROF` (`interrupt.c:327-465`) | `:sb-safepoint` (`safepoint.c`), still `mprotect`s a page to trap; single-threaded build needs neither |
| Resuming Lisp from a signal | `arrange_return_to_lisp_function` rewrites the ucontext (`interrupt.c:1326-1415`) | none; must become a polled flag |
| Stack guard pages | `os_protect` (`validate.c:107-150`) for control, binding, alien stacks; `undefined_alien_address` guard (`validate.c:59`) | none; explicit bounds checks |
| Fixed space addresses | `validate.c:69` `allocate_hardwired_spaces` at addresses from `gc-space-setup` (`generic/parms.lisp:56`) | dynamic space is relocatable (`coreparse.c:577` `relocate_heap`); `:relocatable-static-space` on arm64/x86-64 |
| Zeroing freed pages | `zero_range_with_mmap` (`gc-common.c:2922`) | `memset` path exists |
| `setjmp`/`longjmp` | LDB only (`interr.c`, `monitor.c`, `print.c`) | build with `--disable-ldb` |
| Calling Lisp from C | `call_into_lisp` in `<arch>-assem.S`; pure-C variant in `funcall.c:29` under `C_STACK_IS_CONTROL_STACK` | riscv puts it in `src/assembly/riscv/assem-rtns.lisp:255` |
| Callbacks from C | `funcall_alien_callback` (`thread.c:786`) | `funcall.c:132` pure-C fallback |
| GC roots on the stack | conservative scan of the control stack (`gencgc.c:1377`, `preserve_pointer` `:2024`) and of saved registers in interrupt contexts | the control stack lives in Lisp-managed memory on all non-x86 targets, so conservative scanning of linear memory works unchanged |

There are no references to wasm, WASI or Emscripten anywhere in the tree.

## 1.5 Tests

`tests/run-tests.sh` runs `run-tests.lisp` inside the target SBCL. Files
are discovered by suffix: `*.pure.lisp` (in process, isolated package,
globaldb diffed before and after), `*.impure.lisp` (fresh child SBCL per
file), `*.{pure,impure}-cload.lisp` (`compile-file` then load),
`*.test.sh` (shell, exit 104 for success). `with-test`
(`tests/test-util.lisp:268-312`) takes `:skipped-on`, `:broken-on`,
`:fails-on`, `:implemented-on` feature expressions evaluated at
macroexpansion time, including `(:vop-existsp NAME)` to gate on a backend
VOP. `tests/ansi-tests.sh` clones and runs the ANSI test suite and diffs
failures against a feature-conditional expected list (with `#+riscv`
style entries that a `#+wasm` port extends). Contrib tests are ordinary
impure files that `(require :sb-x)` and load `contrib/sb-x/tests.lisp`.

CI (`.github/workflows/`): `linux.yml` runs the full suite on x86/x86-64 in
several feature configurations and runs `build-all-cores.sh` for all ten
crossbuild backends; `linux-qemu.yml` builds and runs the ANSI tests under
qemu-user for ppc64le and riscv64 (the regression suite is commented out
as too slow under emulation); `cl-host.yml` builds with ECL and CLISP as
the host Lisp.

Build-time programs that must run on the target (`tools-for-build/`):
`grovel-headers.c`, `determine-endianness.c`, the `os-provides-*-test.c`
probes run by `grovel-features.sh` (exit 104 means "feature present"), and
the contrib grovelers (`contrib/make-contrib.lisp:14-46` compiles and runs
a C program). crossbuild-runner replaces them with checked-in tables;
Android replaces them with `android_run`. Wasm needs both: a checked-in
`crossbuild-runner/backends/wasm/` for host-only CI, and a `wasm_run`
wrapper for real builds.
