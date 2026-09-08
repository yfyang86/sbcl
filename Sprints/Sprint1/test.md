# Sprint 1 — test (UAT)

Acceptance criterion for the sprint: every spike answers its question
with a runnable check, and `uat.sh` passes. `uat.sh` re-runs every spike
from source (builds the C stand-ins with wasi-sdk, rebuilds the Rust
host, re-assembles the `.wat` files, recompiles the runtime files) and
checks the outcome each spike was designed to establish. It does not
re-run `make-host-1` or the crossbuild (those take about fifteen minutes
combined); it checks their products in `obj/`.

Run from the repository root:

```
Sprints/Sprint1/uat.sh
```

## Result

```
== tools
PASS  wasmtime present
PASS  wasm-tools present
PASS  wasi-sdk clang present
PASS  host sbcl present
PASS  node present
== S0.1 tool chain
PASS  S0.1 runtime.wasm + plugin.wasm build with wasi-sdk
PASS  S0.1 hello world runs under wasmtime
PASS  S0.1 Rust host builds
PASS  S0.1 runtime-instantiated module installs into shared table and is called via C
PASS  S0.1 sbcl-wasm runner executes a WASI command module
== S0.2 exception handling and tail calls
PASS  S0.2 eh.wat validates with all features
PASS  S0.2 node: unwind through 1000 frames catches at target 500
PASS  S0.2 node: 10^7 direct and indirect tail calls do not overflow
PASS  S0.2 wasmtime: unwind through 1000 frames catches at target 500
PASS  S0.2 wasmtime: 10^7 indirect tail calls
== S0.3 control-flow encodings
PASS  S0.3 both encodings validate
PASS  S0.3 node: dispatch-loop results equal structured results (bench.mjs asserts)
PASS  S0.3 wasmtime: fib 32 equal in both encodings
== S0.4 runtime compile
PASS  S0.4 genesis headers exist for the wasm target
PASS  S0.4 target-os.h is the WASI stub
PASS  S0.4 at least 32 of 42 runtime files compile to wasm32-wasip1
== S0.5 dev loop
PASS  S0.5 :wasm is a target keyword
PASS  S0.5 make-host-1 produced the cross-compiler fasls for the wasm backend
PASS  S0.5 crossbuild-runner built xc.core for wasm
PASS  S0.5 crossbuild-runner built a wasm cold core
== S0.6 wasm64
PASS  S0.6 memory64 module validates
PASS  S0.6 wasmtime runs memory64 by default
PASS  S0.6 node runs memory64 by default

passed=28 failed=0
```

## What each check establishes

| Check | Establishes |
|---|---|
| S0.1 runtime-instantiated module … called via C | design 2.2: runtime `compile` = instantiate a module against the shared memory and table |
| S0.1 sbcl-wasm runner | the Rust host can serve as `wasm_run` for the build stages |
| S0.2 unwind through 1000 frames | design 2.6: Wasm exception handling for `throw`/`unwind`, catch-and-rethrow per frame |
| S0.2 10^7 tail calls | `return_call_indirect` usable for `tail-call` VOPs |
| S0.3 results equal | the dispatch-loop lowering is a correct encoding of arbitrary CFGs |
| S0.4 32 of 42 runtime files compile | the runtime port is feature gating plus the listed files, not a rewrite |
| S0.5 xc.core and wasm.core exist | the host-only development loop works end to end, including genesis |
| S0.6 memory64 by default | wasm64 is not blocked by engines |

Timings and the S0.3 ratios are in `verify.md`; they are measurements,
not pass/fail criteria.
