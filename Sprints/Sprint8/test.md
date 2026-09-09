# Sprint 8 — test record (UAT)

`uat.sh` (full mode: `build-wasm.sh host`, pass-1 and pass-2 from
scratch, the runtime with the extended linkage table, the groveled
constants reproduced, the collector checks with the heap verifier,
foreign calls and `compile-file`, the warm load to `output/sbcl.core`,
the saved core, the two test files, the Sprint 7 checks, level 0, the
after-xc core and level 1; about 10 minutes on an idle 4-core machine
with Wasmtime's cache warm). `UAT_FAST=1` skips the two Lisp builds and
checks their products, `UAT_SKIP_WARM=1` skips the warm load and uses the
existing `output/sbcl.core`. Output: `uat-output.txt`; logs and probe
outputs next to it.

Result: **29 checks passed, 0 failed** (`uat-output.txt`, fast mode
without the warm load, on the products of the full run; fast mode skips
the after-xc rebuild, so it has one check fewer than the full run's 30). The full run
(`uat-output-full.txt`, 27 passed, 3 failed) built everything from
scratch; its three failures were defects of the script, not of the
port: the linkage-table check read the runtime step's summary instead
of its log (`obj/wasm-build/runtime.log`), the weak-pointer probe let
the compiler drop its "live" list before the collection (nothing used
the variable afterwards, so the precise collector rightly broke the
pointer; the probe now reads the list after the collection), and the
64-bit foreign-call check expected the wrong minute (3900000000 is
2023-08-02 21:20:00 UTC, which the output showed). The checks were
corrected and the script rerun against the same products.

| Group | Checks |
|---|---|
| toolchain | wasi-sdk present; `sbcl-wasm` builds |
| Lisp side | pass-1 and pass-2 from scratch (`xc.core`, `wasm.core`, `wasm-core.wasm`); the core module validates |
| runtime | `src/runtime/sbcl.wasm` builds with no warnings and validates; the linkage table was extended for code loaded at run time (52 names the warm sources and the tests use, `coalesce_similar_objects`, `sysconf`); the groveled constants reproduce |
| the garbage collector | `(gc)` and `(gc :full t)` with the heap verifier clean before and after each; allocation stress (6 million vectors through the automatic trigger, 100,000 live conses intact); an EQ hash table of 2,000 keys through five collections; weak pointers (the live referent kept, the dead one broken); `defun`, `compile` and an error after collections (the store barrier and the code "written" flag) |
| foreign calls and files | a foreign call with a 64-bit integer (`get_timezone`'s `time_t` through `decode-universal-time`); `compile-file` writes a fasl with the Wasm code, `load` instantiates it, the functions survive a collection |
| the warm load and the saved core | `tools-for-build/wasm-warm.sh` produces `output/sbcl.core` and `output/sbcl-core.wasm`; the saved core restarts (7,125 run-time modules instantiated again) and evaluates; PCL and the warm functions are there (`find-class`, `describe`); the stdin REPL defines `fib` and prints 6765; CLOS (`defclass`, `defmethod`, an accessor through `compile`); foreign calls and variables from the evaluator; **`tests/gc-smoketest.pure.lisp` passes (3 tests) and `tests/coreparse.pure.lisp` passes (1 test)** (the exit criterion, loaded the way `run-tests.lisp`'s pure runner loads them, with `test-util`) |
| regressions (Sprint 7) | `--eval '(print (+ 1 2))'` prints 3 in the cold core; `--version`; an internal error enters the condition system |
| regressions (levels 0 and 1) | level-0: 16 checks; after-xc core rebuilt; level-1: 444 argument sets, 0 failures |

## Timings (full run)

| Step | Time |
|---|---|
| pass-1 | 1.5 min |
| pass-2 (cross-compile with 4 jobs, and genesis) | 1.5 min |
| runtime build (two links) | 1 min |
| the collector checks (verifier, stress, hash table, weak pointers) | 15 s |
| warm load, compile phase (68 files) | 4 min |
| warm load, load and save phase | 30 s |
| the saved core to `--eval` and exit (Wasmtime's cache warm) | 3.2 s (the cold core: 1.5 s) |
| `gc-smoketest` and `coreparse` | 20 s |
| after-xc core and level 1 | 1.5 min |

The compile phase took 25 minutes on its first run of the day while
another build shared the machine, and about 8 minutes alone before the
GC trigger was armed (`develop.md`, item 15); the figures above are the
UAT's.

## Checked by hand, not in the script

- The saved core's `load` of a source file (`tests/test-util.lisp`)
  compiles and calls through `sysconf` and `setenv` (`develop.md`,
  items 18 and 13).
- Heap exhaustion in the cold core (a loop allocating vectors until
  the 512 MiB run out) signals `heap-exhausted-error`, which
  `handler-case` catches; the collection that the trigger requests is
  never taken inside a loop without calls (`verify.md`, item 4).
- A collection under `SBCL_WASM_VERIFY_GC=1` across the load of all
  68 warm fasls with a 256 MiB heap (31 collections) reports nothing.
- `SBCL_WASM_CHECK_FDEFNS=61788` on the saved core reports no fdefn,
  simple-fun or function linkage cell at or above the table's size.
