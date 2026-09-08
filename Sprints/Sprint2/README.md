# Sprint 2 — target definition, Wasm assembler, module writer

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 1, "Sprint 1: target
definition and assembler" (Sprint 1 in this directory was Phase 0).

Status: complete, UAT green (`test.md`). Findings and decisions in
`verify.md`.

| Deliverable | Status |
|---|---|
| `src/compiler/wasm/parms.lisp`: 32-bit words, linear-memory layout, soft card marks, trap codes | done |
| `src/compiler/wasm/vm.lisp`: thread-struct register file, storage bases and classes, frame slots, fixup kinds | done |
| `src/compiler/wasm/insts.lisp`: Wasm instruction encoder (LEB128, fixed-width fixup immediates, control pseudo-instructions) | done |
| `src/compiler/wasm/module.lisp`: module writer (all sections plus the name section) | done |
| `src/compiler/wasm/macros.lisp`: `load-reg`/`store-reg`, memory and stack access, symbol access | done |
| `move.lisp`, `float.lisp` move functions; `type-vops.lisp` tag tests; NLX state VOPs | done (real code) |
| Every other VOP the compiler front end names: skeletons with exact operand shapes and placeholder generators | done (541 forms) |
| `make-host-1` and genesis pass 1 for the wasm backend | done |
| `crossbuild-runner` pass-1 (`obj/xbuild/wasm/xc.core`) | done |
| Level-0 tests (`tests/wasm/`) validated by wasm-tools and executed by wasmtime | done, 27 Lisp checks + 11 tool checks |

Records: `develop.md`, `test.md` (UAT), `verify.md`. The sprint branch
`sprint2` is merged into `wasm-dev` with `--no-ff` once `uat.sh` is green.
