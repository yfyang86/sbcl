# Sprint 3 — test (UAT)

Acceptance criteria are the sprint's exit criteria from
`doc/wasm-port/04-sprints.md` (Phase 1, "Sprint 2: function assembler and
simple VOPs"): the dispatch-loop lowering and the simple VOP families are
real, the mini-runtime and the compiler-only differential rig exist, and
fifty differential tests pass under Wasmtime comparing with the host SBCL.

`uat.sh` rebuilds everything (about fifteen minutes); `UAT_FAST=1 uat.sh`
checks the products instead. Run from the repository root:

```
Sprints/Sprint3/uat.sh
```

## Result

```
== cross-compiler
PASS  crossbuild pass-1 builds obj/xbuild/wasm/xc.core
PASS  the whole tree cross-compiles into after-xc.core
PASS  pass-1 log has no warnings
PASS  unimplemented VOP worklist written
PASS  no placeholder generators remain in the simple VOP families
== level 0
PASS  level-0: 16 checks, all modules validate and run
PASS  level-0 ran the function assembler tests (dispatch loop, jump table)
== differential rig
PASS  mini-runtime builds (wasi-sdk)
PASS  Rust driver builds
== level 1
PASS  level-1: level1: passed=271 failed=0
PASS  at least fifty level-1 cases pass (got 271)
PASS  no case skipped (not compiled or unimplemented VOP)

passed=12 failed=0
```

Level-1 detail (`XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh`,
log in `level1.log`): 98 cases from `tests/wasm/diff/cases.lisp`, 271
argument sets, one module per case validated with
`wasm-tools validate --features all` and run by the Rust driver under
wasmtime 45 against `tests/wasm/minirt.wasm`. Coverage by family:

| Family | Cases |
|---|---|
| constants, argument passing | const-42, identity-fixnum, first/second-of-two, const-char/nil/t, const-big-fixnum, const-negative |
| fixnum arithmetic | add, sub, add-c, sub-c, one-plus, one-minus, negate, mul, mul-c, truncate-q/-r, rem, mod, floor-q, abs, max, min, mv-bind-truncate |
| logical operations, shifts | logand/logior/logxor(-c), lognot, logtest, ash-left-c, ash-right-c, ash-left-var, ash-right-var, ash-var-signed, ldb, integer-length, logcount, evenp, oddp |
| comparisons | less, greater, less-equal, greater-equal, num-equal, num-not-equal, eql-fixnum, eq, zerop, plusp, minusp, less-c, in-range |
| control flow | if-then-else, not, null, and, or, cond-sign, when-unless, sum-loop, count-down, fib-iter, let-shadow, flet-inline, case-fixnum |
| characters | char-code, code-char, char=, char<, char>, char-roundtrip, characterp |
| lists (runtime allocation) | cons-car, cons-cdr, consp, consp-cons, listp, list-cadr, list-sum, list-star, rplaca, rplacd, endp, list-length-loop |
| symbols and type predicates | symbolp, integerp, numberp, fixnump, stringp, functionp, vectorp, eq-t |

Two failures found and fixed on the way (recorded in `develop.md`):
`logcount` with an argument outside the target's fixnum range (a test
error; `target-word` now rejects it) and `symbolp` on T (the static
symbol had no header in the mini-runtime's memory; the rig pokes the
static symbol headers before each case).
