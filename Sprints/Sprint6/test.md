# Sprint 6 — test record (UAT)

`uat.sh` (full mode: rebuilds pass-1 and pass-2, then genesis alone with
the map file, the runtime, the host, the cold core run and the
regressions; about 35 minutes). Output: `uat-output.txt`; logs next to
it (`pass1.log`, `pass2.log`, `genesis-map.log`, `build-runtime.log`,
`cold-core.txt`, `spin-deadline.txt`, `spin-ctrlc.txt`, `level0.log`,
`after-xc.log`, `level1.log`).

Result: **24 checks passed, 0 failed** (`uat-output.txt`).

| Group | Checks |
|---|---|
| Lisp side | pass-1 (`xc.core`), pass-2 (`wasm.core`, `wasm-core.wasm`, symbols), genesis alone reproduces the core, the core module validates, the map file is written |
| runtime | wasi-sdk present; `src/runtime/sbcl.wasm` builds with no warnings and validates; it imports `sbcl_host.instantiate` and exports `alloc`, `alloc_list`, `internal_error`, `pending_interrupt`, `memory`, `__indirect_function_table` |
| host | `sbcl-wasm` builds; `--version` prints `SBCL 2.6.8.wasm-dev...`; `--help` prints the usage; `tests/wasm/spin.c` compiles; `SBCL_WASM_TIMEOUT=2` stops it with a backtrace; Ctrl-C once notes the interrupt, twice terminates |
| the cold core | the core loads and every required foreign symbol links; the core module (43,492 functions) instantiates at table 4096..47588; `call_into_lisp` enters `!COLD-INIT` (table index 46413); no unknown import is hit; `coreindex.py` decodes the map |
| regressions | level-0: 16 checks; after-xc core rebuilt; level-1: 442 argument sets, 0 failures |

## How far cold-init gets

With the entry-order, `symbol-hash`, foreign-cell and CODE-save fixes
(`develop.md`, section 3) the cold core runs `!COLD-INIT` through
`!make-cold-stderr-stream`, the three stream variable assignments and
`!signal-function-cold-init`, and stops inside `!printer-control-init`:

```
!COLD-INIT (body) -> !PRINTER-CONTROL-INIT (body)
  -> MAKE-PPRINT-DISPATCH-TABLE (body) -> %MAKE-HASH-TABLE (body)
out of bounds memory access at 0xfffffffd
registers: NARGS 0xc CSP 0x3010011c CFP 0xc OCFP 0 LEXENV NIL CODE 0 ...
```

(`cold-core.txt`; frames decoded with `coreindex.py off:...`). The frame
pointer holds a small fixnum where `%make-hash-table` reads a slot, so a
frame or register slot is being overwritten between the `%make-hash-table`
entry and the fault: the first item for Sprint 7, which owns the Lisp side
of errors and the debugger. This satisfies the plan's exit criterion
("reaches the cold-init entry function, which may then fail").

## Timings

| Step | Time |
|---|---|
| runtime build (`wasm-build-runtime.sh`, 4 jobs) | about 1 minute |
| core module compile in Wasmtime, first time | 24–27 s |
| core module from Wasmtime's cache (later runs) | 0.8 s |
| core module instantiate | 7 ms |
| `--version` end to end | under 0.1 s |
