# Sprint 1 — Phase 0 spikes

Plan reference: `doc/wasm-port/04-sprints.md` (Phase 0) and
`doc/wasm-port/06-risks-and-spikes.md` (S0.1–S0.7).

Status: complete, UAT 28/28 (`test.md`). Results and decisions in `verify.md`.

Goal: retire the design unknowns before Sprint 2 commits to the backend
design. Every spike leaves a runnable artifact under `spikes/` and a
written result in `verify.md`.

| Spike | Question | Status |
|---|---|---|
| S0.1 | Tool chain closes: wasi-sdk → Wasmtime via a Rust host; runtime module instantiation into a shared table; `Module::new` latency | done |
| S0.2 | Exception handling and tail calls in real engines | done |
| S0.3 | Cost of the dispatch-loop control-flow encoding | done |
| S0.4 | What breaks compiling `src/runtime` to `wasm32-wasip1` | done |
| S0.5 | Development loop: `:wasm` target keyword + crossbuild-runner pass-1 | done |
| S0.6 | wasm32 or wasm64 | done |
| S0.7 | gencgc can treat a thread-struct register area as conservative roots | done |

Records, in the order the sprint loop runs them:

1. `develop.md` — what was built, with commands to reproduce.
2. `test.md` — acceptance tests (UAT) and their results.
3. `verify.md` — verification of each spike's question, and further study.
4. Commit to `wasm-dev`: the sprint branch `sprint1` is merged into
   `wasm-dev` with `--no-ff` once `test.md` is green, and `wasm-dev` is
   pushed. Only `wasm-dev` is pushed.
