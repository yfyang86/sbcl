# Sprint 7 — test record (UAT)

`uat.sh` (full mode: `build-wasm.sh host`, the groveled constants
reproduced, pass-1 and pass-2 from scratch, the runtime, the cold core
to the REPL, the Sprint 6 checks, level 0, the after-xc core and level 1;
about 40 minutes). `UAT_FAST=1` skips the two Lisp builds and checks
their products instead (about 8 minutes). Output: `uat-output.txt`; logs
next to it (`host.log`, `grovel.log`, `lisp.log`, `build-runtime.log`,
`cold-init.txt`, `version.txt`, `repl.txt`, `error.txt`, `unhandled.txt`,
`spin-deadline.txt`, `level0.log`, `after-xc.log`, `level1.log`).

Result: **28 checks passed, 0 failed** (`uat-output.txt`, fast mode on
the products of the full run; fast mode skips the after-xc rebuild, so
it has one check fewer than the full run's 29). The full run (`uat-output-full.txt`,
27 passed, 2 failed) built everything from scratch; its two failures
were defects of the script, not of the port: the exit-criterion check
compared the output line against `3` exactly while `print` writes `3`
followed by a space, and the stdin REPL check passed
`--non-interactive`, which quits after the command line instead of
entering the REPL. Both checks were corrected and the script rerun
against the same products.

| Group | Checks |
|---|---|
| toolchain | wasi-sdk present; `sbcl-wasm` builds; `wasm-grovel-headers.sh` reproduces the checked-in groveled constants |
| Lisp side | pass-1 and pass-2 from scratch (`xc.core`, `wasm.core`, `wasm-core.wasm`); the core module validates; the map file; genesis gives the target `*wasm-routine-table*` and `*wasm-table-next*` |
| runtime | `src/runtime/sbcl.wasm` builds with no warnings and validates; exports `alloc`, `alloc_list`, `internal_error`, `pending_interrupt`, `memory`, `__indirect_function_table` |
| cold init | the core module (43,404 functions, table 4096..47500) instantiates; cold-init prints through Lisp streams; the cold-init `compile` calls load as run-time modules (four modules of 1–2 functions at table 47500..47506); no unknown import, internal error or deadline; **`--eval '(print (+ 1 2))'` prints 3** (the exit criterion); `(lisp-implementation-version)` is `2.6.8.wasm-dev...`; the stdin REPL defines `fib` and prints `(fib 20)` = 6765; `(car 3)` at run time signals a `type-error` caught by `handler-case` ("The value 3 is not of type LIST"); an unhandled error under `--non-interactive` prints the condition and the erring frame and exits 1; `(exit :code 7)` exits 7 |
| regressions (Sprint 6) | `--version`, `--help`, the spin program and the deadline backtrace, `coreindex.py` |
| regressions (levels 0 and 1) | level-0: 16 checks; after-xc core rebuilt; level-1: 444 argument sets, 0 failures (two more than Sprint 6: `mv-entry-values-3`) |

## Timings

| Step | Time |
|---|---|
| pass-1 | 4 min |
| pass-2 (cross-compile and genesis) | 15 min |
| runtime build | 1 min |
| the core module, first compile (Wasmtime, 43,404 functions, 41 MB) | 26 s |
| the core module from Wasmtime's cache | 0.8 s |
| `--eval '(print (+ 1 2))'` end to end, cached | 2.5 s |
| after-xc core and level 1 | 10 min |

## Checked by hand, not in the script

- `(gc)` stops in the collector (`verify.md`, open item 4); allocating
  200,000 ten-element vectors without a collection works.
- The debugger from the REPL prints the condition, the restarts and the
  erring frame and reads commands from standard input when it is not
  a pipe (under a pipe it clears the input and returns to the REPL,
  as the host SBCL does).
- `sb-ext:exit` with and without `:abort` returns the code from
  `--eval` and from the REPL.
