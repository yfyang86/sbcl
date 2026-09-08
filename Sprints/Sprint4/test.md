# Sprint 4 — test record (UAT)

`uat.sh` is the acceptance test; `uat-output.txt` is its last run. Exit
criteria (plan Sprint 3, `doc/wasm-port/04-sprints.md`): the whole tree
cross-compiles with zero unimplemented VOPs, and differential tests for
calls, multiple values, catch/throw, unwind-protect, dynamic extent and
float arithmetic pass.

## Result

`passed=21 failed=0` (full mode: both Lisp builds rerun from scratch).

| Check | Result |
|---|---|
| crossbuild pass-1 (`pass1.sh`) builds `xc.core`, log without warnings | pass |
| whole tree cross-compiles (`after-xc.sh`), 301/301 files | pass |
| `unimplemented-vops.txt`: `0 unimplemented VOPs used 0 times` | pass |
| no `vop-not-yet-implemented` generator left in `src/compiler/wasm` | pass |
| level 0 (`tests/wasm/run-level0.sh`): 16 module checks, 27 Lisp checks | pass |
| mini-runtime and Rust driver build | pass |
| level 1 (`tests/wasm/run-level1.sh` on `after-xc.core`): 162 cases, 442 argument sets | 442/442 pass |
| assembly-routine module `asm.wasm` built and validates | pass |
| Sprint 4 families (labels recursion, unknown values, throw from a local callee, unwind-protect with throw, dynamic-extent list, two optionals, &rest sum, float multiply, double round) | pass |

## Level-1 coverage added this sprint (64 cases)

- local calls: `labels-sum-rec`, `labels-fib-rec`, `labels-tail-loop`,
  `flet-called-twice`, `labels-mutual`, `local-call-in-loop`
- multiple values: `mv-known-local`, `mv-unknown-local`, `mv-unknown-three`,
  `mv-entry-values`, `mv-entry-no-values`, `mv-tail-local-unknown`,
  `mv-prog1`, `mv-double-values`
- catch/throw: `catch-normal`, `catch-throw-same-fn`, `catch-throw-t-tag`,
  `catch-throw-conditional`, `catch-throw-from-local`, `catch-nested-outer`,
  `catch-nested-inner`, `catch-throw-mv`, `catch-normal-mv`, `catch-in-loop`,
  `catch-throw-deep-local`
- unwind-protect and block exits: `uwp-normal`, `uwp-throw`, `uwp-throw-value`,
  `uwp-nested-throw`, `uwp-throw-from-local`, `block-return-from-local`,
  `uwp-return-from`
- dynamic extent: `dx-list`, `dx-cons`
- entry points: `optional-arg`, `optional-two`, `optional-supplied`,
  `rest-count` (1 to 6 arguments), `rest-sum` (0 to 7), `rest-first`,
  `rest-after-two`, `more-arg-values`
- floats: `sf-add`, `sf-mul`, `sf-div`, `sf-sub-lt`, `sf-compare`, `sf-eq`,
  `sf-abs-neg`, `sf-round`, `sf-loop-sum`, `df-add`, `df-mul`, `df-div`,
  `df-compare`, `df-eq`, `df-round`, `df-loop-sum`, `sf-to-df`, `df-to-sf`,
  `sf-local-call`, `df-local-call-mv`, `sf-bits`, `df-high-bits`

## Regressions

The 98 Sprint 3 cases (271 argument sets) pass unchanged under the
per-environment function assembler (`level1-s3.log`).

## How the failures were found and fixed

Each case was first run on its own with a timeout
(`level1-s4-individual.log`); the compiler hang on
`block-return-from-local` (stale predicate tables), the routine module's
trailer, negative memarg offsets, the reordering of `call-out` results
and the self-tail-calling empty environment of `rest-first` came out of
that sweep. Details in `verify.md`.
