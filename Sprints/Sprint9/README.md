# Sprint 9 — self-hosting and the first baseline

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 2, "Sprint 8:
self-hosting and the first baseline" (the directory numbering is one
ahead of the plan because Sprint 1 here was Phase 0).

Goal: `compile-file` and `load` of fasls; `disassemble`; the pure-Lisp
contribs (`asdf`, `sb-rt`, `sb-md5`, `sb-cltl2`, `sb-rotate-byte`,
`sb-aclrepl`, `sb-executable`, `sb-queue`); `tests/subr.sh` and
`run-sbcl.sh` routing through `sbcl-wasm`; `parallel-exec.sh` under
Wasmtime.
Exit criterion: `tests/run-tests.sh` runs to completion and produces the
first baseline report (`doc/wasm-port/baselines/sprint-8.txt`, the
plan's name) listing every failing test; `tests/ansi-tests.sh` runs to
completion.

Status: in progress. Records: `develop.md`, `test.md` (UAT), `verify.md`;
script: `uat.sh`. Build and run with `build-wasm.sh` (see
`WASM-Manual.md`); the sprint branch `sprint9` is merged into `wasm-dev`
with `--no-ff` once `uat.sh` is green.
