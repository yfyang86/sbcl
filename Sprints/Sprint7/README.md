# Sprint 7 — cold init

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 2, "Sprint 6: cold
init" (the directory numbering is one ahead of the plan because Sprint 1
here was Phase 0). The plan budgets two sprints for this work.

Goal: drive `!cold-init` (`src/code/cold-init.lisp`) to the REPL.
Exit criterion: `sbcl-wasm src/runtime/sbcl.wasm --core obj/xbuild/wasm.core
--eval '(print (+ 1 2))'` prints 3.

Status: complete, UAT green (28/28 fast mode on the products of the
full run, `test.md`); the exit criterion is met. Findings and open items
in `verify.md` (first among them: the GC, which is the next sprint's
subject, and the C shadow stack leak on non-local exits through C).

| Deliverable | Status |
|---|---|
| the entry trace: a safe point in every XEP, `SBCL_WASM_TRACE_ENTRIES`, `wasm-coreindex.py --annotate`, `wasm-func.py` | done |
| `!cold-init` to the REPL: 13 defects fixed (`develop.md`), groveled constants regenerated for the target | done |
| code compiled at run time loaded as modules (`wasm-install-code`, `wasm_instantiate_module`, `*wasm-table-next*`) | done |
| internal errors enter the condition system (`wasm_internal_error` → `internal-error` with a synthesized context) | done |
| `--eval '(print (+ 1 2))'` prints 3; the stdin REPL; `handler-case`; `exit` codes | done |
| `%primitive print` | not needed: cold-init printed through Lisp streams as soon as the stream init ran |
| continuable errors, backtraces below the interrupted frame, interrupt delivery | deferred (`verify.md`) |

Records: `develop.md`, `test.md` (UAT), `verify.md`; script: `uat.sh`. Build and run with `build-wasm.sh` (see
`WASM-Manual.md`); the sprint branch `sprint7` is merged into `wasm-dev`
with `--no-ff` once `uat.sh` is green.
