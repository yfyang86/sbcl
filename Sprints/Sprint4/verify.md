# Sprint 4 — verification notes and further study

## What was verified

- The whole source tree cross-compiles with the wasm backend and **zero
  unimplemented VOPs** (`obj/xbuild/wasm/unimplemented-vops.txt`), from a
  clean pass-1 build with no warnings.
- Level 0 (assembler, module writer, function assembler) passes with the
  v2 function assembler and its three scratch locals.
- The Sprint 3 level-1 cases (98 cases, 271 argument sets) pass unchanged
  under the per-environment function model.
- The Sprint 4 level-1 families pass: recursive and mutually recursive
  LABELS (local calls, tail-call loops), FLET called twice, known and
  unknown multiple values through local calls, VALUES at the entry,
  catch/throw (same function, from a local callee, nested, in a loop,
  with multiple values, static symbol tags), unwind-protect (normal,
  throw, nested, from a local callee, return-from through it), block
  return-from out of a local function, dynamic-extent lists and conses,
  &optional (with supplied-p) and &rest entries with up to seven
  arguments (stack arguments), single and double float arithmetic,
  comparisons, conversions, rounding, bits, local calls with float
  arguments and multiple float values (64 cases; the whole level-1 suite
  is 162 cases, 442 argument sets, all passing).

## Findings

1. **Cross-compiler predicate tables were stale** (`vm-typetran.lisp`).
   `*backend-type-predicates-grouped*` is a `defglobal` whose initform the
   cross-compiler evaluates at compile time, before the file's own
   `define-type-predicate` forms run; `backend-type-predicate` therefore
   never returned `fixnump`, `double-float-p`, `bignump` or any
   `simple-array-*-p` in the cross-compiler, and `transform-typep`
   expanded `(typep x 'fixnum)` into itself forever for a shape produced
   by `(the fixnum (+ (f a) (f b) 100))` with a NOTINLINE local function.
   The riscv32 cross-compiler built from the same tree hangs the same way,
   so this is not backend-specific. Fixed by recomputing the tables at
   load time under `#+sb-xc-host`; code generated for typep of these types
   is now the predicate VOP instead of the generic expansion.
2. **Memarg offsets are unsigned.** Every helper that folds a constant
   displacement into a load or store now checks the sign; `copy-more-arg`
   was the first user of a negative frame index.
3. **The routine module's code ends at the end-of-text label**; the
   trailer `assemble-sections` appends decoded as instructions and failed
   validation.
4. **Wasm has no swap**: a value already on the operand stack cannot be
   stored to an address pushed after it. Every function now starts with
   three scratch locals (i32, f32, f64) for VOPs that need to reorder;
   `call-out` results were the first user.
5. **Assembly routines have the Lisp function type**: a routine that
   returns pushes a dummy result and the caller drops it.
6. **An empty environment tail-called itself.** `&rest` processing gave
   `rest-first` an environment whose only block is empty; its chunk exit
   resolved "the function starting at this position" to itself. The exit
   now skips the current function and prefers one that has code there.
7. **Fixup flavors**: `+fixup-flavors+` is a 16-entry vector encoded in
   fasls; the three wasm flavors are appended `#+wasm`, and the perfect
   hash journal `xperfecthash30.lisp-expr` gained the entry (recorded with
   `tools-for-build/perfecthash`).

## Limits of the rig, and what the cases avoid

The rig has no heap, no code header and no fdefns, so a case cannot use:

- a full call (named, static or through a function object): generic
  arithmetic on values of unknown range (`(+ (catch ...) r)`, `(incf c)`
  under a catch where the variable's derived type is lost),
  `multiply-fixnums` for `(* fixnum 5)` without a fixnum-provable result,
  `last`, `multiple-value-list` (`#'list` is a constant);
- boxed constants: float literals and folded `(coerce 2 'single-float)`,
  bounded float declarations (their range checks compare against float
  constants), fdefns of global functions. A folded constant read through
  the rig's fake code header yields garbage silently (`df-local-call-mv`
  computed with a wrong clamp bound before its literals became
  arguments), so a wrong *value* rather than a trap can mean a constant;
- foreign calls: `(floor single-float)` goes through a C routine, so the
  `sf-floor` case was dropped (`round` and `truncate` are open-coded);
- `dotimes` whose body contains a catch: the iteration variable's range
  is not inferred across the non-local exit and its `1+` becomes a
  generic full call; the case uses an explicit `do` with a declared
  range. Float values are made from
  fixnum arguments and ranges are derived, or clamped with `min`/`max`
  of argument-derived values, so that `truncate` has a fixnum result.

These are limits of the test harness, not of the backend: the code the
compiler emits for them is the ordinary full-call or constant-load path,
exercised once the loader exists.

## Open items and further study

- **Float constants** are loaded from the code header like any boxed
  constant. Wasm has `f32.const`/`f64.const`; an immediate SC for floats
  (as x86-64's `fp-single-immediate`) with a move function into
  `single-reg`/`double-reg` would avoid the boxed constants for unboxed
  uses and let the rig test bounded float types. Planned for the sprint
  that adds constants to the rig.
- **Overflow VOPs**: the compiler calls `two-arg-+` when the result of a
  fixnum addition is not provably a fixnum; `overflow+`-style VOPs
  (`sb-c::overflow-transform`) would open-code the checked addition.
  Not needed for correctness.
- **`%unwind` is the translation of the `unwind` routine**; the unwind
  target is a thread word, so a nested unwind inside a cleanup that itself
  throws overwrites it only after the inner handler ran. Verified by the
  nested unwind-protect cases; worth a stress case with a throw from a
  cleanup once full calls exist.
- **Loader and genesis** (next sprint): `:function-type`,
  `:assembly-routine-entry`, `:foreign`, `:foreign-dataref` and
  `:code-coverage-index` fixups are dumped unresolved; code objects need
  table slots for their simple-funs at load time; fdefn raw-addr words
  must be initialised to the trampolines.
- **debug-int**: the frame layout constants (`ra-save-offset`) are already
  `#+wasm` alongside riscv; backtraces will need the Wasm frame walk once
  the runtime exists.
