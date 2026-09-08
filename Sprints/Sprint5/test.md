# Sprint 5 — test record (UAT)

`uat.sh` is the acceptance test; `uat-output.txt` is its last run. Exit
criteria (plan Sprint 4, `doc/wasm-port/04-sprints.md`): `crossbuild-runner`
pass-2 produces a wasm cold core and a core module that validates; pass-1
and pass-2 headers are identical; the core module loads (not runs) in
Wasmtime and V8, with its size and compile time recorded against the
S0.1 budget.

## Result

`passed=15 failed=0` (full mode: pass-1, pass-2, genesis alone, after-xc,
level 0, level 1, both loaders).

| Check | Result |
|---|---|
| crossbuild pass-1 (`pass1.sh`) builds `xc.core`, log without warnings | pass |
| crossbuild pass-2 (`pass2.sh`): tree cross-compiled, genesis complete | pass |
| `obj/xbuild/wasm.core` written (41 MiB) | pass |
| `obj/xbuild/wasm-core.wasm` written (36 MiB, 43,487 functions from 20,052 code components, table 4096..47582) and validates | pass |
| `wasm-core.wasm.symbols`: 168 foreign symbols | pass |
| `genesis-only.sh` reproduces the core; pass-1-style and pass-2 headers identical (31 files) | pass |
| Rust loader `load-core` (Wasmtime 45) | pass |
| Node loader `tests/wasm/load-core.mjs` (V8, Node 22) | pass |
| level 0: 16 module checks | pass |
| after-xc core and level 1: 442/442 argument sets | pass |

## What the checks exercise

| Check | What it proves |
|---|---|
| pass-1 builds `xc.core` without warnings | the cross-compiler, with the new fop, dumper hook and lowering, compiles cleanly on the host |
| pass-2 (`crossbuild-runner/pass-2.lisp`) | every file of the tree cross-compiles with the real dumper, each component lowered and carried in its fasl; genesis cold-loads all of them |
| `obj/xbuild/wasm.core`, `obj/xbuild/wasm-core.wasm` written; module validates | the core and the core module are complete and well-formed (`wasm-tools validate --features all`) |
| `wasm-core.wasm.symbols` | the required foreign symbols are recorded for the runtime |
| `genesis-only.sh`, headers identical | genesis alone reproduces the products, and the header set written with all fasls equals the one written the make-host-1 way |
| Rust loader (`load-core`) | Wasmtime compiles and instantiates the module against a stub environment and the element segment fills the table range; compile time recorded |
| Node loader (`tests/wasm/load-core.mjs`) | the same in V8 (`--experimental-wasm-exnref`) |
| level 0 | the assembler, module writer and function assembler tests still pass |
| after-xc and level 1 | the 162 differential cases (442 argument sets) of Sprints 3 and 4 still pass with the reworked lowering (entry arms, simple-fun headers) |

## Timings and sizes

| | Wasmtime 45 (Cranelift) | V8 (Node 22, lazy) |
|---|---|---|
| module size | 38,101,654 bytes | 38,101,654 bytes |
| compile | 20.9 s | 0.11 s |
| instantiate | 6 ms | 8 ms |
| table range filled | yes | yes |

Against the S0.1 budget (Cranelift: 7.1 s for 5.6 MB of tiny functions),
the core module confirms that the standalone host needs precompiled
modules and that browsers start cheaply through lazy compilation
(`verify.md`).
