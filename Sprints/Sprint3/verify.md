# Sprint 3 — verify and further study

## Exit criteria

| Criterion (plan, Phase 1 Sprint 2) | Result |
|---|---|
| dispatch-loop control-flow lowering | `func-asm.lisp`; level-0 `funcasm` tests (loop with `jump-if`, `jump-table`, elsewhere code) validate and run under wasmtime |
| `macros.lisp`, `move.lisp`, `arith.lisp`, `pred.lisp`, `type-vops.lisp`, `cell.lisp`, `memory.lisp`, `system.lisp`, `char.lisp`, `sap.lisp` with real generators | done; the whole source tree cross-compiles (`after-xc.core`); remaining placeholders are listed in `obj/xbuild/wasm/unimplemented-vops.txt` |
| mini-runtime and level-1 differential rig | `tests/wasm/minirt.c`, `wasm/crates/sbcl-wasm-test`, `tests/wasm/diff/` |
| fifty differential tests pass under Wasmtime against the host SBCL | see `test.md` |

## What was verified about the design

**The dispatch loop carries real compiler output.** Every level-1
module is the compiler's own IR2 for the case, lowered by
`wasm-function-body`: the arg-count check, the fixnum type checks with
their error traps in the elsewhere section, `if`/`cond`/`case` chains,
`dotimes` and `loop` back edges, and the bignum slow paths of
`move-from-signed` all run through the `br_table` dispatch. 98 modules
validate with `wasm-tools validate --features all`; 271 argument sets
compute the word the host SBCL computed.

**Register file in linear memory.** The register file (thread global +
slot offset) works as designed: no VOP needed a Wasm local, the operand
stack is the only temporary, and `tmp-tn` (slot 28) serves the few
generators that need a second copy of a value (header tests,
`widetag-of`, `code-from-mumble`).

**Operand lifetimes are the subtle part of a stack backend.** A result
store may reuse an argument's register the moment it is written, so a
generator that stores a result and then reads an argument again is
wrong. The convention (arith.lisp header) is a single `store-reg` per
result with all reads before it, and `:to :save` on the arguments of
multi-result VOPs. The differential cases that exercise two-result VOPs
(`truncate`, `multiple-value-bind`) pass.

**Allocation through the runtime works for lists, bignums and vectors.**
`emit-allocate` calls the `alloc`/`alloc_list` imports; the cons, list,
`list*`, `rplaca`/`rplacd` and 50-element list cases run against the
mini-runtime's bump allocator, and the bignum path of `move-from-signed`
is emitted (never taken by the cases, whose values stay fixnums).

**Type predicates.** `%test-headers` handles single widetags and
ranges; `stringp`, `vectorp`, `numberp`, `integerp`, `functionp`,
`symbolp`, `consp`, `characterp` and `(typep x '(integer 0 10))` give
the host's answers on fixnums, characters, T and NIL. `symbolp` on T
needs the static symbol's header in memory; the rig writes the headers
of every static symbol before each case (`!poke` lines in `cases.txt`).

**The cross-compiler needs the whole tree compiled first.** The level-1
rig compiles in `after-xc.core`, not in the pass-1 image: in the bare
image the `typep` transforms loop on target types that are only
defined by cross-compiling `src/code`. Tolerant placeholders make that
whole-tree compile possible with 179 VOPs still unimplemented (125,368
uses, the top entries being the call VOPs, `data-vector-ref/set` for
simple vectors, float moves and `push-values`), which is the worklist
for the next two sprints.

**The differential rig has to read the cases in a target package.** In
the cross-compiler image `COMMON-LISP-USER` is the host's package, whose
`numberp` is not the `sb-xc:numberp` the compiler knows as a type
predicate (the `fold-type-predicate` transform then fails its
assertion). Cases are read in `SB-IMPL`, and their function names are
prefixed with `WASM-CASE-` so that a case named `numberp` does not
redefine the predicate the compiler is using.

## Known gaps carried into the next sprints

- **Card marking.** The target uses `:soft-card-marks`, so every
  descriptor store into a heap object must mark its card. The stores in
  `cell.lisp`, `memory.lisp`, `alloc.lisp` and `system.lisp`
  (`code-header-set`) do not yet; the GC sprint adds the mark (one byte
  store indexed by `address >> gencgc-card-shift` masked with the card
  table mask) to `storew` for descriptor values. Until then nothing runs
  a GC, so this is invisible.
- **Allocation** always goes through the `alloc` import; there is no
  inline bump allocation and `stack-allocate-p` is ignored (heap
  allocation is a correct implementation of dynamic extent).
- **`i32.div_s` traps** on `most-negative / -1`. `fast-truncate/signed` is
  only selected when the quotient fits `(signed-byte 32)`, so the
  compiler never emits that division; noted in the VOP.
- **`set-fdefn-fun`, `fdefn-makunbound`, `mark-covered`** and the whole
  of `call.lisp` beyond leaf functions, `values.lisp`, `nlx.lisp`,
  `array.lisp`, `float.lisp`, `c-call.lisp` are placeholders (the plan's
  Sprints 3 and 4).
- **Error trap arguments** are stored as SC+OFFSET words in the thread's
  error-argument area, one per argument, and the runtime import receives
  `(kind code nargs)`; the debugger side that decodes them is part of
  the runtime port.

## Further study

- **Card marks before the GC sprint.** The soft-card-mark store barrier
  is a few instructions per descriptor store (`address >>
  gencgc-card-shift`, mask, one byte store). Decide whether `storew`
  marks unconditionally for descriptor values or whether the generic
  `emit-gengc-barrier` protocol of x86-64 is followed, before the runtime
  sprint makes GC observable.
- **Inline allocation.** Every allocation is a call into the runtime;
  once the runtime exists, a bump pointer in the thread area (design 2.8)
  removes the call from the fast path. The `alloc` import stays as the
  slow path.
- **Error-trap arguments.** The SC+OFFSET words go to a fixed 16-word
  area in the thread structure; nested traps (an error inside an error
  handler that traps again) reuse it, which is fine because the runtime
  copies the words out before running Lisp. Confirm when
  `internal-error-args` is exercised by the runtime port.
- **Register pressure.** With 32 word slots there is no spilling in
  the cases; larger functions will show whether `nl0-nl7` plus `l0-l5`
  suffice or whether the register file should grow (it is a constant in
  `vm.lisp` and `minirt.c`).
- **Coverage marks** (`mark-covered`) need a code-relative data area;
  deferred with `sb-cover` (plan, Phase 4).
