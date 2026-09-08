# Sprint 5 — genesis, fasls and the core module

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 1, "Sprint 4: genesis,
fasls and the core module" (the directory numbering is one ahead of the
plan because Sprint 1 here was Phase 0).

Status: complete, UAT green (`test.md`). Findings and open items in
`verify.md`.

| Deliverable | Status |
|---|---|
| fasls carry each component's lowered Wasm functions (`fop-wasm-code`, blob format with patch tables, `serialize-wasm-code`/`parse-wasm-code`) | done |
| genesis collects the blobs, assigns table indices from `+core-table-base+`, patches function, routine, type, trampoline, foreign and layout-id references, writes simple-fun self slots and fdefn raw addresses, emits the core module and the required foreign symbols | done |
| `crossbuild-runner` pass-2 produces `obj/xbuild/wasm.core` (41 MiB), `obj/xbuild/wasm-core.wasm` (36 MiB, 43,487 functions from 20,052 code components, validates) and `wasm-core.wasm.symbols` (168 foreign symbols) | done |
| pass-1 and pass-2 genesis headers identical | done (31 files) |
| the core module loads in Wasmtime (`load-core`, Rust) and V8 (`tests/wasm/load-core.mjs`, Node); size and compile time recorded against the S0.1 budget | done: Wasmtime compiles it in about 21 s, V8 (lazy) in 0.1 s, both instantiate in milliseconds |

Records: `develop.md`, `test.md` (UAT), `verify.md`. Scripts: `pass1.sh`,
`pass2.sh`, `uat.sh`. The sprint branch `sprint5` is merged into `wasm-dev`
with `--no-ff` once `uat.sh` is green.
