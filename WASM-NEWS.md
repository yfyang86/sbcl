# SBCL on WebAssembly — release notes and change log

This file is the `wasm-dev` port's counterpart of `NEWS`: what each
release of the port contains, against which SBCL it was cut, and where
the details live (`Sprints/SprintN/`, `doc/wasm-port/`,
`WASM-Manual.md`).

## 2.4.8-wasm.1 — the first release (2026-09-15)

The complete SBCL system — compiler, runtime, garbage collector, PCL,
the condition system, `compile-file`/`load`, `save-lisp-and-die`, and
the pure-Lisp contribs — compiled to `wasm32-wasip1`, running under
Wasmtime (the Rust host) and in the browser (V8, the Sprint 14 web
host). Everything below is the work of Sprints 1–14
(`doc/wasm-port/04-sprints.md`) plus the master sync that followed.

### The system

- A new compiler backend (`src/compiler/wasm/`, `src/assembly/wasm/`):
  Wasm instruction encoder, function assembler, module writer; every
  compiled component is a Wasm module whose functions join a shared
  funcref table. Register caching in Wasm locals between flush points
  (Sprint 13); NARGS and A0..A3 as the Wasm parameters of the Lisp
  function type; `return_call_indirect` tail calls; structured control
  flow through a stackifier over `try_table`/`throw` (Sprint 12).
- The C runtime compiled with wasi-sdk 27 (`src/runtime/sbcl.wasm`):
  the generational collector over linear memory with exact roots,
  streams, the loader, timers, `run-program` through the host.
- Genesis for wasm (`#+wasm` in `src/compiler/generic/genesis.lisp`):
  the cold core and its 44 MB core module, table indices in simple-fun
  headers, the foreign symbol table.
- Two hosts: `sbcl-wasm` (Rust, Wasmtime — timers, epoch interruption,
  module cache, the reference implementation of the `sbcl_host`
  contract, `SBCL-Handoff.md`) and the browser host of Sprint 14
  (`wasm/web/`: a Web Worker, a WASI preview 1 shim over an in-memory
  file system, the `sbcl_host` contract in JavaScript, a REPL page
  served by `wasm/web/serve.mjs`; verified in Chromium and Firefox).
- Pure-Lisp contribs, including ASDF (third-party systems load,
  `WASM-Manual.md` section 4.1) and the `sb-js` skeleton
  (`js-call`'s error until a JavaScript entry point exists).

### Conformance and tests

- The ANSI suite: 21,752 tests, 0 unexpected failures (Sprint 13's
  run; `FORMAT.E.26` fails at random as it does upstream).
- The regression suite: 403 files, a documented failure list
  (`doc/wasm-port/baselines/sprint-14-sync.txt`: 52 files, dominated
  by dynamic-extent allocation, debugger frame walking, threads and
  sockets — the port has no stack allocation and no threads).
- Level 0 (assembler/module writer), level 1 (444 differential cases
  against the host compiler), each sprint's `uat.sh`, and the
  Playwright suite for the browser host (8 tests, two browsers).

### Performance (`doc/wasm-port/baselines/sprint-13-cl-bench.md`)

cl-bench's geometric mean 8.2× native at Sprint 12, 1.2–3× on the
compute-bound loops at Sprint 13; call-heavy kernels 5–25×;
`ctak`/`crc40` 80–100× (the runtime's unwind, 32-bit bignum words).
Startup: about 1 s under Wasmtime from cache, 0.2 s in Chromium to the
REPL. The known optimizations are the Sprint 13 backlog's first items
(the call sequence, the unwind, 64-bit bignums).

### Known limitations

No threads, no sockets, no foreign libraries or callbacks, no
dynamic-extent (stack) allocation, no debugger backtrace or stepping;
`save-lisp-and-die` cores are per-host files, not executables. Fixnums
are 30 bits (wasm32). The details: `SBCL-Handoff.md` section 5.

### How to build and run

`./build-wasm.sh` (about 5 minutes on an Apple-silicon Mac, 35 on the
4-core Linux container; `WASM-Manual.md` section 3), then
`tools-for-build/wasm-sbcl.sh --core output/sbcl.core` or
`node wasm/web/serve.mjs` for the browser.

### Change log (the sprint history)

| Sprint | Delivered | Record |
|---|---|---|
| 1 | target definition, Wasm assembler, module writer | `Sprints/Sprint1/` |
| 2 | function assembler, the first VOPs, the differential rig (level 1) | `Sprints/Sprint2/` |
| 3 | calls, frames, allocation, floats, non-local exits | `Sprints/Sprint3/` |
| 4 | genesis, fasls, the core module | `Sprints/Sprint4/` |
| 5 | the C runtime under wasi-sdk, the first Wasmtime host | `Sprints/Sprint5/` |
| 6 | cold init to the toplevel | `Sprints/Sprint6/` |
| 7 | streams, `--eval`, the REPL | `Sprints/Sprint7/` |
| 8 | the collector working, the warm load, `sbcl.core` | `Sprints/Sprint8/` |
| 9 | the regression suite green to completion | `Sprints/Sprint9/` |
| 10 | errors, the debugger REPL, the ANSI suite started | `Sprints/Sprint10/` |
| 11 | ANSI suite clean; timers; the stack guard | `Sprints/Sprint11/` |
| 12 | structured control flow (the stackifier), contribs | `Sprints/Sprint12/` |
| 13 | register caching, the calling convention, cl-bench baseline | `Sprints/Sprint13/` |
| 14 | the browser host: worker, WASI shim, `sbcl_host`, REPL page, Playwright; `sb-js` skeleton | `Sprints/Sprint14/` |
| — | master sync: 14 upstream fixes picked, `%closure-fun` on wasm, the BSD-xargs test-runner fix | `doc/wasm-port/baselines/sprint-14-sync.txt` |
