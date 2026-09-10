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

Status: done. The stackifier is the default encoding (34 fallbacks in
pass-2, 61 in the warm load, all loops with two entries), `wasm-opt`
runs in the build's `opt` step, both suites are at or better than the
last baseline, cl-bench improved by 1.18 on the geometric mean against
the factor of about 2 predicted (the criterion not met, with the
reason and the next measure in `verify.md`). Records: `develop.md`,
`test.md`, `verify.md`; the baselines `doc/wasm-port/baselines/sprint-12.txt`
and `sprint-12-cl-bench.md`.
