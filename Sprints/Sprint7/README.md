# Sprint 7 — cold init

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 2, "Sprint 6: cold
init" (the directory numbering is one ahead of the plan because Sprint 1
here was Phase 0). The plan budgets two sprints for this work.

Goal: drive `!cold-init` (`src/code/cold-init.lisp`) to the REPL.
Exit criterion: `sbcl-wasm src/runtime/sbcl.wasm --core obj/xbuild/wasm.core
--eval '(print (+ 1 2))'` prints 3.

Status: in progress. Records: `develop.md`, `test.md` (UAT), `verify.md`;
scripts: `uat.sh`. Build and run with `build-wasm.sh` (see
`WASM-Manual.md`); the sprint branch `sprint7` is merged into `wasm-dev`
with `--no-ff` once `uat.sh` is green.
