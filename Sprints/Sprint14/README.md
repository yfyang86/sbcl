# Sprint 14 — the browser host

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 14:
browser host".

Goal: run the port under V8 in a browser: `wasm/web` with a Web Worker
running the runtime and core, a WASI shim, the `sbcl_host`
implementation with synchronous module instantiation in the worker, a
REPL page; an `sb-js` contrib skeleton (`js_call`); a Playwright suite
(boot, REPL round trip, `compile` of a function, a subset of pure
tests executed in the worker).

Exit criterion (the plan): the REPL page runs in Chromium and Firefox;
the Playwright suite is in the nightly CI; startup time and core
module size are recorded.

Status: complete. Records: `develop.md`, `test.md`, `verify.md`,
`uat.sh` (11 checks). The sprint branch `sprint14` is merged into
`wasm-dev` with `--no-ff` when its records are complete.
