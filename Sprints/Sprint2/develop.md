# Sprint 2 — develop

Branch `sprint2` from `wasm-dev`. Everything below is reproducible with the
commands shown; the UAT (`uat.sh`) runs them.

## What was built

### Target definition

- `src/compiler/wasm/parms.lisp`: 32-bit words (`:wasm32` fasl tag),
  32 KiB GC pages with 32 soft-card-mark cards each, no float traps,
  linear-memory layout with the Lisp spaces from 16 MiB and dynamic
  space from 256 MiB (`gc-space-setup #x01000000 :dynamic-space-start
  #x10000000`), 4-byte alien linkage entries (a function entry will hold
  a table index), trap codes, static symbols.
- `src/compiler/wasm/vm.lisp`: the register file of design 2.4: 32 word
  slots (nargs, csp, cfp, ocfp, nfp, nsp, lexenv, code, lip, cfunc,
  a0–a3, l0–l5, nl0–nl7, tmp, ra, thread, reserved) and 32 float slots;
  storage bases and every storage class `generic/primtype.lisp`
  requires; `boxed-regs` for the GC; frame slots `ocfp-save-offset` 0,
  `ra-save-offset` 1, `code-save-offset` 2, `nfp-save-offset` 3; fixup
  kinds `:absolute` and `:leb128`.

### Instruction encoder (`src/compiler/wasm/insts.lisp`)

`define-instruction` forms for the Wasm 3.0 core instructions the backend
will emit: control (`block`, `loop`, `if`, `else`, `end`, `br`, `br_if`,
`br_table`, `return`, `call`, `call_indirect`, `return_call`,
`return_call_indirect`, `try_table`, `throw`, `throw_ref`,
`unreachable`, `nop`), reference, variable and table instructions, all
loads and stores with memargs, `memory.size/grow/copy/fill`, all i32,
i64, f32, f64 numeric instructions, conversions, sign extension and
saturating truncation, `select` and `drop`. LEB128 emitters, a
fixed-width five-byte LEB128 for fixup immediates (`i32.const` and
`call` accept a fixup), float constants as bit patterns so the
cross-compiler's non-native floats can be emitted, and the data
pseudo-instructions `byte`, `word`, `machine-word`.

Control pseudo-instructions `jump`, `jump-if`, `jump-table`,
`func-begin`, `func-end` take assembler labels, emit no bytes, and record
`control-note`s on the segment (new generic slot `backend-data` in
`sb-assem:segment`) when the segment is finalized, so their positions are
final. `segment-control-notes` returns them in emission order. The
function assembler that consumes them is Sprint 3.

### Module writer (`src/compiler/wasm/module.lisp`)

Portable CL. `make-wasm-module`, `wasm-type-index` (deduplicated function
types), `wasm-import-{function,table,memory,global,tag}`,
`wasm-add-{function,table,memory,global,tag,export,elements,data}`,
`wasm-set-start`, `wasm-module-octets`, `write-wasm-module`,
`assemble-octets`. Emits the type, import, function, table, memory, tag,
global, export, start, element, data-count, code and data sections and
the "name" custom section (function names), in the order the binary
format requires. Added to `build-order.lisp-expr` after the assembler.

### Backend files needed by the compiler front end

The front end names VOPs at macroexpansion time (`(vop allocate-frame
...)` in `ir2tran.lisp`, `#.(template-or-lose 'save-dynamic-state)` in
`late-nlx.lisp`, and so on) and checks that move functions exist for
every storage class. So `make-host-1` cannot succeed with empty VOP
files. Real code was written where it is small and settled:

- `macros.lisp`: `load-reg`/`store-reg`, `load-freg`/`store-freg`,
  `loadw`/`storew`, `emit-load-word`/`emit-store-word` (negative
  displacements folded into the address because memarg offsets are
  unsigned), `load-immediate-word`, `load-symbol`, `load-symbol-value`,
  `store-symbol-value`, stack-slot access, dynamic-state cells,
  `load/store-index`, and the placeholders `vop-not-yet-implemented`,
  `emit-error-break`.
- `move.lisp`: all move functions (immediate, number, character, SAP,
  constant, stack, number stack) and the `move`/`move-arg` VOPs.
- `float.lisp`: single, double and complex move functions.
- `type-vops.lisp`: `%test-fixnum`, `%test-immediate`, `%test-lowtag`
  as real Wasm; `%test-headers` placeholder.
- `nlx.lisp`: `save-dynamic-state`, `restore-dynamic-state`,
  `current-stack-pointer`, `current-binding-pointer`, `current-nsp`,
  `set-nsp`.
- `call.lisp`: `emit-block-header` and the frame-location functions
  (`make-return-pc-passing-location` and friends,
  `select-component-format`).
- `src/assembly/wasm/support.lisp`: `generate-call-sequence` (a direct
  `call` through an `:assembly-routine` fixup); `assem-rtns.lisp`:
  `throw` and `unwind` routine definitions with placeholder bodies.

Every other VOP is a **skeleton**: exact `:args`, `:results`, `:info`,
`:arg-types`, `:result-types`, `:translate`, `:policy`, `:conditional`,
`:save-p`, `:move-args`, `:variant` clauses, and a generator that calls
`vop-not-yet-implemented`. They were generated, not typed: a riscv32
cross-compiler image was built (`crossbuild-runner` pass-1 for
`riscv32`), and `gen-skeletons.lisp` printed `define-vop` forms from its
`sb-c::*backend-parsed-vops*` table, which includes macro-generated VOPs
that no source grep would find. `merge-skeletons.py` appended them to the
matching backend file. VOPs that generic files define (type predicates,
error VOPs, header-word accessors, `insert-safepoint`) and the
riscv-specific modular-arithmetic VOPs were removed. 529 `define-vop`
forms remain across 21 files.

```
sbcl ... riscv32 riscv "(:UNIX :LINUX :ELF :OS-PROVIDES-CLOCK-GETTIME :LITTLE-ENDIAN)" < crossbuild-runner/pass-1.lisp
sbcl --core obj/xbuild/riscv32/xc.core --load Sprints/Sprint2/gen-skeletons.lisp --eval '(sb-vm::gen "names.txt" "/tmp/skel/")'
python3 Sprints/Sprint2/merge-skeletons.py /tmp/skel/
```

### Generic changes

- `src/compiler/assem.lisp`: `backend-data` slot on `segment`.
- `src/cold/build-order.lisp-expr`: `#+wasm ("src/compiler/wasm/module")`.
- `crossbuild-runner/backends/wasm/features`: `:soft-card-marks` added,
  `:memory-barrier-vops` dropped.

### Tests

`tests/wasm/level0/assembler.lisp` runs inside `obj/xbuild/wasm/xc.core`
and `tests/wasm/run-level0.sh` drives it: LEB128 and constant encodings;
a two-argument function; a function exercising memory, i32/i64/f32/f64
arithmetic, conversions, `block`/`loop`/`br_if`, `if`/`else`,
`br_table`, `call_indirect` through an element segment, `select`; a
module with a tag, `try_table`/`throw` and `return_call`; the control
pseudo-instructions' notes and positions; fixup bytes and notes;
imports, globals, active and passive data, element offsets from an
imported global, and the name section. Every module is validated with
`wasm-tools validate --features all` and the exported functions are run
under wasmtime against expected values the Lisp side writes.

## Build commands

```
sh make-config.sh --arch=wasm --xc-host='sbcl --dynamic-space-size 2GB --lose-on-corruption --disable-ldb --disable-debugger'
sh make-host-1.sh                       # about 4 minutes
sbcl --noinform --disable-debugger --noprint --no-userinit --no-sysinit \
     wasm wasm "(:UNIX :LINUX :ELF :OS-PROVIDES-CLOCK-GETTIME :LITTLE-ENDIAN)" < crossbuild-runner/pass-1.lisp
tests/wasm/run-level0.sh
```

`host1.sh` in this directory runs make-host-1 and prints the first failure.
