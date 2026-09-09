# Sprint 8 — garbage collector and warm load

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 2, "Sprint 7: garbage
collector and warm load" (the directory numbering is one ahead of the
plan because Sprint 1 here was Phase 0).

Goal: `gencgc` on the target with the register area as a root set,
`(gc :full t)`, the automatic trigger, allocation stress;
`save-lisp-and-die` through WASI; the warm load (`src/cold/warm.lisp`:
PCL and the rest, compiled by the target itself).
Exit criterion: `output/sbcl.core` is produced; the saved core restarts
and reaches the REPL; `tests/gc-smoketest.pure.lisp` and
`tests/coreparse.pure.lisp` pass.

Status: done, pending the UAT (`uat.sh`; `test.md` has the record). Records: `develop.md`, `test.md` (UAT), `verify.md`;
script: `uat.sh`. Build and run with `build-wasm.sh` (see
`WASM-Manual.md`); the sprint branch `sprint8` is merged into `wasm-dev`
with `--no-ff` once `uat.sh` is green.
