# Sprint 4 — development log

Branch `sprint4`, merged into `wasm-dev` when `uat.sh` is green. The
sprint covers plan Sprint 3 ("calls, frames, allocation, floats, NLX",
`doc/wasm-port/04-sprints.md`): the rest of the backend, so that the
whole tree cross-compiles with no placeholder generator left, and the
differential rig exercises calls, unknown values and non-local exit.

## 1. Function assembler v2 (`src/compiler/wasm/func-asm.lisp`)

Sprint 3 lowered a component into one dispatch-loop function. Calls need
real Wasm functions (the stack of Wasm frames *is* the Lisp control
stack of return points), so the assembler now emits one Wasm function
per IR2 environment:

- `codegen.lisp` records `(block-label . environment)` for every IR2
  block (`sb-vm::*wasm-block-labels*`, `#+wasm`); `wasm-component-functions`
  groups the code ranges by environment, in order of first block, and
  gives every function its entry (the `entry-info` whose offset is the
  function's first label, if any).
- Each function is still a dispatch loop over its own arms (labels in
  its ranges plus the elsewhere chunks its notes jump to). A jump to a
  label of *another* function is lowered to `return_call` of that
  function with the arm index preselected (IR2 lowers tail local calls to
  jumps or fall-through into the callee's first block; both frames share
  the same Lisp frame, so a Wasm tail call is exactly right).
- New pseudo-instructions in `insts.lisp`: `call-label` (local call:
  `call` of the function owning the label), `tail-call-label`
  (`return_call`), `label-index` (`i32.const` of the label's arm index, for
  NLX blocks), `nlx-entry` (marks a label as an NLX entry).
- Every Lisp function has Wasm type 0, `() -> (i32)`: the result is the
  values flag (0: one value in A0; 1: multiple values, count in NARGS,
  first ones in A0..A3, all of them at OCFP on the stack with CSP past
  them). `return_call` needs the callee to have the caller's type, which
  this convention guarantees.
- NLX: a function with `nlx-entry` notes gets a `$fp` local capturing CFP
  at entry, and its dispatcher is wrapped in `block $H / try_table (catch
  lisp_unwind -> $H)`. The handler compares the thread's unwind target
  block's CFP with `$fp`; on a match it loads the entry arm index from
  the block and re-enters the dispatcher, otherwise it rethrows.
- Assembly routines are imported as `"lisp" name` right after the four
  runtime imports; `:assembly-routine` fixups are patched to import (or,
  inside the routine module, local) function indices.
  `:function-type` fixups (name `(params results)`) are patched to the
  module's type indices by `patch-type-indices` when a function is added
  to a module. `:foreign`, `:foreign-dataref`, `:assembly-routine-entry`
  and `:code-coverage-index` fixups stay in the fasl for the loader
  (Sprint 5); `dump.lisp` learned the three new flavors (`#+wasm`).
- Every function starts with three scratch locals (i32, f32, f64,
  `+scratch-i32-local+` and friends): Wasm has no swap, so a VOP that has
  a value on the operand stack and needs to push the address it is
  stored to parks the value in a local (`call-out` results). `$pc` and
  the jump-table scratch follow them.
- An environment whose first block is empty starts at the same position
  as the next environment; the chunk exit of such a function must fall
  into the *other* function starting there (`function-continuing-at`),
  not into itself (found by `rest-first`: `&rest` processing produced an
  empty environment that tail-called itself forever).
- The code of a routine file ends at the end-of-text label
  `assemble-sections` emits; the trailer after it is not code (found
  when the routine module failed validation: the trailer words decoded
  as `if` blocks).

## 2. Calling convention (`call.lisp`, `values.lisp`)

Registers are the thread-area word slots of Sprint 3 (NARGS, CSP, CFP,
OCFP, NFP, NSP, LEXENV, CODE, LIP, CFUNC, A0-A3, L0-L5, NL0-NL7, TMP,
RA). Frames are on the control stack, growing upward; the number stack
grows downward from `number_stack_end`.

- Full calls go through `call_indirect` (type 0) on a table index. A
  named call loads the fdefn's function into CODE and calls its raw-addr
  word, which holds the table index (the simple-fun's self slot for a
  simple function; the `closure-tramp` or `undefined-tramp` entry
  otherwise — `set-fdefn-fun` and `fdefn-makunbound` in `cell.lisp`,
  `make-fdefn` in `alloc.lisp`, `:assembly-routine-entry` fixups). An
  unnamed call (`emit-function-object-entry`) follows closure and
  funcallable-instance headers to the simple-fun and calls its self slot.
  The XEP recovers the code object from CODE (`xep-allocate-frame`).
- Local calls: `call-label`; known calls drop the flag; tail local calls
  are jumps (section 1). `default-unknown-values` and
  `receive-unknown-values` read the flag from the operand stack.
- `tail-call-variable`, `copy-more-arg`, `more-arg`, `%listify-rest-args`,
  `%more-arg-context`, `verify-arg-count`, the returns, `push-values`,
  `values-list`, `%more-arg-values`, `%%nip-values`: straightforward
  transcriptions of the riscv generators onto the operand-stack style.
  `load-frame-word`/`store-frame-word` now fold negative word indices
  (used by `copy-more-arg` when moving arguments down) into an address
  add, since a memarg offset is unsigned.

## 3. Non-local exit (`nlx.lisp`, `src/assembly/wasm/assem-rtns.lisp`)

Catch and unwind blocks store CFP, CODE and the entry's arm index
(`label-index`) instead of a return PC. `throw` walks the catch chain
(`*current-catch-block*`, a static symbol value); `unwind` runs the
unwind-protect cleanups between the current and the target block (each
cleanup entry calls `%continue-unwind`, i.e. `unwind` again), then stores
the target block in the thread's unwind-target word, restores CFP and
CODE from the block and throws the `lisp_unwind` tag (index 0, imported
as `"env" "lisp_unwind"`). Assembly routines are ordinary type-0
functions: a routine that returns pushes `i32.const 0`, and the call
sequence drops the result (`support.lisp`).

## 4. Floats, arrays, foreign calls, the rest

- `float.lisp`: f32/f64 arithmetic, comparisons (`emit-conditional-branch`),
  conversions (`convert_i32_s/u`, `demote`/`promote`), `round`/`truncate`
  via `nearest`/`trunc_sat`, boxing/unboxing, bits accessors, software
  float modes (thread word 452), complex floats as register pairs. The
  float access macros dispatch on the format at run time, so a
  `:variant-vars` format works.
- `array.lisp`: headers, dimensions, bounds checks (`i32.ge_u` on
  fixnums), every data-vector reffer/setter family including the sub-byte
  vectors, `vector-raw-bits`, `data-vector-cas`, `array-atomic-incf/word`.
- `c-call.lisp`: arguments go to number-stack slots of the block
  `alloc-number-stack-space` reserves, addressed from NSP (the base that
  `make-call-out-tns` hands to the argument moves); `call-out` pushes them
  and does `call_indirect` with a `:function-type` fixup of the alien
  function's signature; results come back on the operand stack.
- `subprim.lisp` (`length/list`), `show.lisp` (`print` through a
  `debug_print` foreign entry), `system.lisp` `mark-covered`.

## 5. Cross-compiler fixes outside the backend

- `src/compiler/generic/vm-typetran.lisp`: `*backend-type-predicates-grouped*`
  and `*backend-union-type-predicates*` are `defglobal`s whose value the
  cross-compiler computes when the file is *compiled*, before its own
  `define-type-predicate` forms are loaded; the fasl then keeps the stale
  value. `backend-type-predicate` never found `fixnump`, `double-float-p`
  or any array predicate, and `transform-typep` looped forever on
  `(the fixnum <unknown>)` in a local-function shape (reproduced with the
  riscv32 cross-compiler too). The tables are recomputed at load time
  under `#+sb-xc-host`.
- `dump.lisp`: three `#+wasm` fixup flavors (section 1).
- `xperfecthash30.lisp-expr`: new entry for the extended flavor vector,
  recorded by `tools-for-build/perfecthash` (built with `make`).

## 6. Rig

`tests/wasm/diff/run-diff.lisp` assembles `src/assembly/wasm/assem-rtns.lisp`
in target mode and writes `asm.wasm`; the Rust driver instantiates it
with its own table base and links it as `"lisp"`; the `lisp_unwind` tag
is shared by every module of a store. Cases are read in `SB-IMPL` with
`WASM-CASE-` prefixed names; `!poke` lines create the static symbol
headers. The driver passes arguments beyond the fourth in the callee's
frame slots, as a full call does, so `&rest` entries with up to seven
arguments are exercised. `host-eval` maps the `SB-XC` and `SB-KERNEL`
symbols of a case (the cross-compiler's `DOUBLE-FLOAT`, `TRUNCATE`,
`SINGLE-FLOAT-BITS`) back to the host's before compiling it on the host.
New cases: `tests/wasm/diff/cases.lisp`, Sprint 4 section (64 cases).
