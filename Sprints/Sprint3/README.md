# Sprint 3 — function assembler, simple VOPs, differential rig

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 1, "Sprint 2: function
assembler and simple VOPs" (the directory numbering is one ahead of the
plan because Sprint 1 here was Phase 0).

Status: complete, UAT green (`test.md`). Findings and decisions in
`verify.md`.

| Deliverable | Status |
|---|---|
| `src/compiler/wasm/func-asm.lisp`: dispatch-loop lowering of a flat code segment into Wasm function bodies, codegen hook, Lisp module builder | done |
| `call.lisp`: leaf-function calling convention (frame setup, arg-count check, single and multiple value return) and error traps | done |
| `arith.lisp`, `pred.lisp`, `type-vops.lisp`, `char.lisp`, `move.lisp`, `memory.lisp`, `cell.lisp`, `system.lisp`, `sap.lisp`, `debug.lisp`, `alloc.lisp` with real generators | done (three placeholders left, listed in `verify.md`) |
| `macros.lisp` helper families: compare and branch, allocation, indexed access, reffer/setter macros for words, bytes, floats, complex floats | done |
| `src/code/wasm-vm.lisp`, C-call TN allocation, `arg-count-sc`/`closure-sc` | done |
| whole source tree cross-compiles into `obj/xbuild/wasm/after-xc.core` with the placeholder worklist in `unimplemented-vops.txt` | done, 301/301 files |
| mini-runtime (`tests/wasm/minirt.c`) and Rust differential driver (`wasm/crates/sbcl-wasm-test`) | done |
| level-1 differential tests (`tests/wasm/diff/`) | 98 cases, 271 argument sets, all pass under wasmtime |

Records: `develop.md`, `test.md` (UAT), `verify.md`. Scripts: `pass1.sh`
(crossbuild pass-1), `after-xc.sh` (whole-tree cross-compile), `uat.sh`,
`replace-vop.py` (skeleton editing helper used early in the sprint). The
sprint branch `sprint3` is merged into `wasm-dev` with `--no-ff` once
`uat.sh` is green.
