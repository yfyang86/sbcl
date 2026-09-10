# Sprint 12 — stackifier

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 11:
stackifier" (the directory numbering is one ahead of the plan).

Goal: structured control flow for the compiled code
(`src/compiler/wasm/stackify.lisp`, design 2.5, encoding 2) with the
dispatch loop as the fallback for irreducible control flow; the loop
safe points in the structured form; `wasm-opt` for the cold core
module; the cost measured with cl-bench against the factor S0.3
predicted.

Exit criterion (the plan): both test suites still clean; the cl-bench
geometric mean improves by the factor S0.3 predicted; no function falls
back to the dispatch loop except the irreducible ones, counted in the
build log.

Status: in progress. Records: `develop.md`, `test.md`, `verify.md`.
The sprint branch `sprint12` is merged into `wasm-dev` with `--no-ff`
when its records are complete.
