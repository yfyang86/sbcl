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

Status: done. The baseline report is `doc/wasm-port/baselines/sprint-8.txt`
(the regression suite: 403 files, 295 passed, 108 did not, 161 failing
tests by name; the ANSI suite: 21,752 tests, 21,539 pass, 192 fail, 21
crashed). Records: `develop.md`, `test.md` (UAT), `verify.md`;
script: `uat.sh` (28 checks, green; `test.md`). Build and run with
`build-wasm.sh` (see `WASM-Manual.md`); the sprint branch `sprint9` is
merged into `wasm-dev` with `--no-ff`.
