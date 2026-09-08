# Sprint 3 — develop

Branch `sprint3` from `wasm-dev`. Plan reference: `doc/wasm-port/04-sprints.md`,
Phase 1, "Sprint 2: function assembler and simple VOPs". Everything below is
reproducible with the commands shown; `uat.sh` runs them.

## What was built

### Function assembler (`src/compiler/wasm/func-asm.lisp`)

The control-flow lowering of design 2.5. The generic assembler produces a
flat byte segment with the control pseudo-instructions of Sprint 2
(`jump`, `jump-if`, `jump-table`, `func-begin`, `func-end`; each now one
NOP byte long so that every label has a distinct position) recorded as
`control-note`s. `wasm-function-body` turns the byte range of one Lisp
function into a valid Wasm function body:

- one `loop` around nested `block`s, one block per jump target, and a
  `br_table` on the local `$pc` at the top of the loop (the dispatch
  loop);
- `jump` becomes `local.set $pc; br <loop>`, `jump-if` becomes
  `if ... end` around it, `jump-table` parks the index in a scratch local
  and branches through the same table (a `block` starts a fresh operand
  stack, which is why the index cannot stay on the stack);
- code in the `:elsewhere` section (error traps) is attributed to the
  function whose range it belongs to and appended to its body.

`wasm-component-functions` splits an assembled component into its entry
points; `sb-vm::wasm-note-component` is called from `codegen.lisp` after
`assemble-sections` and hands `(entry-info body locals)` triples to
`*wasm-component-hook*`, which the differential rig uses. `make-lisp-module`
and `add-lisp-functions` build a module whose imports are the runtime's
(`env.memory`, `env.__indirect_function_table`, `env.thread`,
`env.table_base`, `env.internal_error`, `env.alloc`, `env.alloc_list`,
`env.pending_interrupt`) and whose functions all have the signature
`[] -> [i32]` of design 2.6 (0 = single value in A0, 1 = multiple values).

### Calling convention, minimal (`call.lisp`)

The VOPs a leaf function needs: `xep-allocate-frame`, `xep-setup-sp`,
`allocate-frame`, `allocate-full-call-frame`, `verify-arg-count` (a
`jump-if` to the arg-count error trap), `return-single`, `return`,
`known-return`, `current-fp`, and the frame-location hooks. Full calls,
tail calls, `&more` and `&optional` entry, unknown-values returns and
the trampolines are the next sprint.

### Simple VOP families (real generators; three placeholders remain, see verify.md)

| File | Content |
|---|---|
| `move.lisp` | move functions, `move`, `move-arg`, `word-move`, `move-to-word/fixnum`, `move-to-word-c`, `move-to-word/integer`, `move-from-word/fixnum`, `move-from-signed` (one-digit bignum through `with-fixed-allocation`), `move-from-fixnum+/-1`, `move-from-unsigned` (one or two digits), `move-word-arg`; every `define-move-vop` registration directly after its VOP (see Findings) |
| `arith.lisp` | fixnum/signed/unsigned `+ - logior logxor logand` and their `-c` variants through one `define-binop`, negate, lognot, all `ash` VOPs (variable-count right shifts in i64 with the count clamped to 63, no branch), `%ash/right`, `integer-length` (`i32.clz`), `logcount` (`i32.popcnt`), `*`, `truncate` (division-by-zero trap checked before `i32.div_s`, which would trap), `<`/`>`/`eql` conditionals through `emit-compare`, `shift-towards-start/end`, modular arithmetic (`+-mod32`, `--mod32`, `*-mod32`, the `modfx` variants, `ash-left-mod32`, `lognot-mod32`), bignum digit VOPs in i64 (`%add-with-carry`, `%subtract-with-borrow`, `%multiply-and-add`, `%multiply`, `%multiply-high`, `%bigfloor`, `%ashr/%ashl/%digit-logical-shift-right`, `%bignum-length/-set-length/-ref/-set`) |
| `pred.lisp` | `branch`, `if-eq`; no conditional moves (`convert-conditional-move-p` is NIL) |
| `type-vops.lisp` | `%test-fixnum`, `%test-immediate`, `%test-lowtag`, `%test-fixnum-and-headers`, `%test-headers` (lowtag check, header byte into `tmp-tn`, one `jump-if` per widetag or range), `symbolp`, `consp`, `signed-byte-32-p`, `unsigned-byte-32-p` |
| `char.lisp` | character moves and coercions, `char-code`, `code-char`, `char=`/`char<`/`char>` |
| `memory.lisp` | `cell-ref`, `cell-set`, `set-instance-hashed` |
| `cell.lisp` | `slot`, `set-slot`, `compare-and-swap-slot` (one thread: load, compare, conditional store), symbol value VOPs with the unbound check, `boundp`, `set`, `safe-fdefn-fun`, `dynbind`/`unbind`/`unbind-to-here`, closure indexing and `closure-init`, `value-cell-set`, `%instance-length`, instance ref/set/cas, raw instance slots for words, floats and complex floats, `%raw-instance-atomic-incf/word`. `set-fdefn-fun` and `fdefn-makunbound` wait for the call convention (they need the trampoline entries) |
| `system.lisp` | `descriptor-hash32`, `widetag-of`, `%structure-is-a` (layout id compared against an immediate or a `:layout-id` fixup in `i32.const`), `%other-pointer-widetag`, `%fun-pointer-widetag`, `get/set-header-data`, stack pointer VOPs, `stack-ref`/`%set-stack-ref`, `code-instructions`, `code-trailer-ref`, `compute-fun`, `code-header-ref/-set`, `%weakvec-ref/-set`, `receive-pending-interrupt` and `do-pending-interrupt` (call the import), `halt` (`unreachable`), barriers as no-ops, `%sqrt`/`%sqrtf`. `mark-covered` is the one placeholder (coverage marks need a code-relative data area) |
| `sap.lisp` | SAP moves, `sap-int`/`int-sap`, `sap+`/`sap-`, every `sap-ref-N` and setter with the `-c` variants, `cas-sap-ref-32/-sap/-lispobj`, `vector-sap` |
| `debug.lisp` | `current-fp-sap`, `code-from-fun`, `%make-lisp-obj`, `get-lisp-obj-address` |
| `alloc.lisp` | `list`/`list*` (through `env.alloc_list`), `fixed-alloc`, `var-alloc`, `make-closure`, `make-value-cell`, `make-unbound-marker`, `allocate-vector-on-heap`, `allocate-vector-on-stack` (heap allocation, dynamic extent ignored until the runtime port), `make-fdefn` (raw-addr 0 until the trampolines exist) |

Helpers added to `macros.lisp`: `emit-conditional-branch`, `emit-compare`,
`emit-allocate` (call the `alloc` or `alloc_list` import, tag the result),
`with-fixed-allocation`, `emit-indexed-address` (a fixnum index is its own
byte offset for word elements; smaller and larger elements shift it),
`emit-load-sized`/`emit-store-sized`, `emit-load-float`/`emit-store-float`,
`load-freg-slot`/`store-freg-slot`, and the reffer/setter macro family
(`define-full-reffer/-setter`, `define-partial-reffer/-setter`,
`define-float-reffer/-setter`, `define-complex-float-reffer/-setter`).
`vm.lisp` gained `short-immediate` (`(or (signed-byte 32) (unsigned-byte 32))`,
since `i32.const` takes a full word) and `short-immediate-fixnum`.

Codegen conventions (`arith.lisp` header): every VOP reads operands with
`load-reg`, computes on the operand stack and stores each result with one
`store-reg`; a result may share a register with an argument as long as no
later store of the same VOP reads that argument, so multi-result VOPs keep
their arguments live `:to :save`. VOP-local labels are only used at
empty-stack points.

### Tolerant placeholders and the whole-tree cross-compile

`vop-not-yet-implemented` (`macros.lisp`) emits `unreachable`, counts the
VOP in `sb-vm::*wasm-unimplemented*` and records it for the component;
`sb-vm::*wasm-strict-vops*` makes it an error. This lets
`tests/wasm/make-after-xc.lisp` cross-compile the entire source tree
(`src/cold/compile-cold-sbcl.lisp` in a fresh host, as pass-2 does) and
save `obj/xbuild/wasm/after-xc.core`, the image the differential rig
compiles in. The image also writes `obj/xbuild/wasm/unimplemented-vops.txt`,
the backend's worklist ordered by use count. Compiling test functions in
the bare pass-1 image is not possible: `typep` transforms re-parse target
types (`classoid` and friends) that only exist after `src/code` is
cross-compiled, and the compiler loops (the riscv32 image behaves the same).

### Differential test rig, level 1 (`doc/wasm-port/05-testing.md`, 5.4)

- `tests/wasm/minirt.c` (wasi-sdk, `build-minirt.sh`): a reactor module
  exporting a growable memory and function table, the thread area, the
  control and number stacks, a bump allocator (`alloc`, `alloc_list`,
  zeroed), `pending_interrupt`, and `reset`.
- `wasm/crates/sbcl-wasm-test` (Rust, wasmtime 45): reads
  `module.wasm position args... => expected name` lines, instantiates the
  mini-runtime, grows the table by 256 entries and instantiates each test
  module at `table_base`, fills the register file (NARGS, A0–A3, CFP = CSP
  = control stack base, NSP), calls the function at `base + position`
  through the table and compares A0 with the expected word. An
  `internal_error` from the code under test becomes a failure naming the
  trap kind and error code.
- `tests/wasm/diff/run-diff.lisp`: runs inside `after-xc.core`, writes a
  `defun` per case (named `WASM-CASE-<name>` in `SB-IMPL`),
  cross-compiles the file in target mode with the component hook
  installed, writes one module per case and the expected words from the
  host SBCL (`target-word` encodes fixnums, characters, T and NIL and
  rejects integers outside the target's fixnum range). `cases.txt` also
  carries `!poke address value` lines with the headers of the static
  symbols, which the driver stores before each case.
  `tests/wasm/diff/cases.lisp` holds the cases (98 cases, 271 argument
  sets: constants, fixnum arithmetic and shifts, logical operations,
  comparisons, control flow and loops, characters, lists through the
  allocator, symbols and type predicates); `tests/wasm/run-level1.sh`
  runs the whole chain.

## Build and run

```
Sprints/Sprint3/pass1.sh          # crossbuild pass-1 -> obj/xbuild/wasm/xc.core (~4 min)
Sprints/Sprint3/after-xc.sh       # whole tree -> obj/xbuild/wasm/after-xc.core (~10 min)
tests/wasm/run-level0.sh          # assembler, module writer, function assembler
tests/wasm/build-minirt.sh; (cd wasm && cargo build --release -p sbcl-wasm-test)
XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh
```

## Findings during development

- `define-move-vop` registrations must follow their VOP immediately, in
  the riscv order. `define-vop` computes operand loading costs at
  macroexpansion time from the coercions registered so far; with the
  registrations appended at the end of `move.lisp`, `move-from-word/fixnum`
  was defined before `move-to-word/fixnum` was registered and the
  cross-compiler failed with "cost info inconsistent with that in effect
  at compile time". The same ordering is now used in `float.lisp`.
- The whole-tree cross-compile is the only real test of the operand
  restrictions: the missing `move-arg` registration for `signed-reg`
  to `descriptor-reg` and the unknown `short-immediate-fixnum` type only
  show up there.
- Variables that `func-asm.lisp` (compiled right after the assembler)
  shares with `macros.lisp` are defined in `func-asm.lisp`.
- `ash-left-modfx` is not a known function on a 32-bit target at the
  time `arith.lisp` is compiled (`info-vector.lisp` carries the same
  FIXME); the VOP translating it is left out.
- Codegen bugs only the validator catches: `emit-allocate` evaluated a
  byte-count form for its value instead of pushing it (`with-fixed-allocation`
  passed `(pad-data-block size)`), so every bignum slow path failed
  validation with "expected i32 but nothing on stack". The macro now
  takes a form that returns an integer or pushes and returns `:pushed`.
- Level-1 arguments must be target fixnums: `(unsigned-byte 30)` is not a
  fixnum on a 30-bit-fixnum target, and the wrapped word made `logcount`
  trap on a non-fixnum argument (correctly). `target-word` now rejects
  such values.
- `symbolp` on T needs T's header in memory; the mini-runtime has no
  static space, so the rig pokes the static symbol headers.
