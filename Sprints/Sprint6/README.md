# Sprint 6 — the runtime port

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 1, "Sprint 5: runtime
port" (the directory numbering is one ahead of the plan because Sprint 1
here was Phase 0).

Status: complete, UAT green (24/24, `test.md`). Findings and open items
in `verify.md`.

| Deliverable | Status |
|---|---|
| `src/runtime` compiles and links with wasi-sdk to `src/runtime/sbcl.wasm`: `Config.wasm-wasi`, `wasm-arch.c`, `wasm-lispregs.h`, `wasm-wasi-os.c`, `wasi-mman.c`, `wasm-interrupt.c`, the generated `wasm-linkage-table.c`; signal, ldb, run-program and sprof code compiled out | done |
| `os_alloc_gc_space` over linear memory (`memory.grow`), `os_link_runtime` over the generated table, `call_into_lisp`/`funcall0..3` as C over `call_indirect`, exported `alloc`, `alloc_list`, `internal_error`, `pending_interrupt` | done |
| `sbcl-wasm` host v0.1: WASI, `sbcl_host.instantiate`, growable shared table, unknown imports as traps, Wasmtime module cache, Ctrl-C through epochs, a run deadline for debugging | done |
| `tools-for-build/wasm-build-runtime.sh`, `tools-for-build/wasm_run.sh`, `tools-for-build/wasm-linkage-table.sh` | done |
| `sbcl.wasm --version` and `--help` under the host | done |
| `coreparse` loads `obj/xbuild/wasm.core`, the core module instantiates against the runtime's memory and table, `call_into_lisp` reaches `!COLD-INIT` | done (how far cold-init gets is recorded in `test.md`) |
| grovel-headers/grovel-features under `wasm_run.sh` | deferred (`verify.md`) |

Records: `develop.md`, `test.md` (UAT), `verify.md`. Scripts: `uat.sh`,
`genesis-map.sh`/`genesis-map.lisp` (genesis alone, with the map file),
`coreindex.py` (backtrace and register decoding). The Lisp side is rebuilt
with `Sprints/Sprint5/pass1.sh` and `pass2.sh`. The sprint branch `sprint6`
is merged into `wasm-dev` with `--no-ff` once `uat.sh` is green.
