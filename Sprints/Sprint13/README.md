# Sprint 13 — register caching and the calling convention

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 12:
register caching and calling convention" (the directory numbering is
one ahead of the plan).

Goal: cache the Lisp registers in Wasm locals between flush points
(the register area stays the truth at function boundaries and around
runtime calls); pass the first four arguments as Wasm parameters and
return `A0` as the Wasm result; `return_call_indirect` for tail calls;
measure.

Exit criterion (the plan): the suites clean; the compute-bound
cl-bench results within 3× of native SBCL under V8 and Wasmtime,
recorded in `doc/wasm-port/baselines/`.

Status: in progress. Records: `develop.md`, `test.md`, `verify.md`.
The sprint branch `sprint13` is merged into `wasm-dev` with `--no-ff`
when its records are complete.
