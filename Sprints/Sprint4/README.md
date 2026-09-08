# Sprint 4 — calls, frames, unknown values, non-local exit, floats

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 1, "Sprint 3: calls,
frames, allocation, floats, NLX" (the directory numbering is one ahead of
the plan because Sprint 1 here was Phase 0).

Status: complete, UAT green (`test.md`). Findings and open items in
`verify.md`.

| Deliverable | Status |
|---|---|
| `func-asm.lisp` v2: one Wasm function per environment, `return_call` edges for tail local calls, `call` for local calls, `label-index` for NLX entries, `try_table` handler around functions with NLX entries, assembly routines as `"lisp"` imports, `call_indirect` type-index fixups | done |
| `call.lisp`: full calling convention (named/unnamed/static full calls, tail calls, local and known calls, unknown-values return and receive, more args, closures, XEP entry) | done |
| `values.lisp`, `nlx.lisp`: unknown values manipulation, catch/unwind blocks, NLX entries on Wasm exception handling | done |
| `src/assembly/wasm/assem-rtns.lisp`: `throw`, `unwind`, `closure-tramp`, `undefined-tramp`; `assemfile.lisp` hook that builds the routine module | done |
| `float.lisp`, `array.lisp`, `c-call.lisp`, `subprim.lisp`, `show.lisp`, `alloc.lisp`/`cell.lisp`/`system.lisp` remaining generators | done |
| whole source tree cross-compiles with zero unimplemented VOPs | done, 301/301 files, `unimplemented-vops.txt` empty |
| rig: assembly-routine module instantiated and linked, unwind tag, `!poke` lines | done |
| level-1 differential tests for local calls, unknown values, catch/throw, unwind-protect, dynamic extent, optional/rest entries, floats | 64 new cases; 162 cases, 442 argument sets in all, all pass under wasmtime |

Records: `develop.md`, `test.md` (UAT), `verify.md`. Scripts: `pass1.sh`,
`after-xc.sh`, `uat.sh`. The sprint branch `sprint4` is merged into
`wasm-dev` with `--no-ff` once `uat.sh` is green.
