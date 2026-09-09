# Sprint 10 — test record (UAT)

`uat.sh` (full mode: `build-wasm.sh host`, pass-1, pass-2, the runtime
and the warm load from scratch, the fixed classes, the triage and tag
checks, the two suites and the second baseline report, the Sprint 9
checks, level 0, the after-xc core and level 1; about two hours, most
of it the suites). `UAT_FAST=1` skips the Lisp builds and the warm load
and checks their products; `UAT_SKIP_SUITES=1` skips the two suites
and checks their logs. Output: `uat-output.txt`; probe outputs next to
it.

Result: **24 checks passed, 0 failed** (`uat-output.txt`, fast mode
without the suites, on the products of the sprint's last full rebuild
and the baseline runs of that build).

| Group | Checks |
|---|---|
| toolchain and build | wasi-sdk present; the host builds and runs the module on its own 256 MB thread; the build products; the linkage table maps undefined functions to the guard and has the C stack helpers |
| the fixed classes | an error branch to the first elsewhere chunk lands (the empty-arm `unreachable`); an undefined alien of a non-void signature signals `undefined-alien-function-error` with its name; `sleep`, `machine-instance`, `tmpfile` and the user database stubs; the C shadow stack pointer is where it was after 20,000 errors caught by `handler-case`; a constant bit index at the top of a word compiles and stores; a core saved under another name gets its module and restarts; a runaway recursion is a trap, not a host abort |
| triage, tags, expected list | `triage.md` classifies every file of the first baseline; the unsupported tests carry `:skipped-on :wasm` tags and file skips with reasons, `SBCL_WASM` for the shell tests; the `#+wasm` ANSI entries, the driver's comparison, `no-float-traps` on this target |
| the suites and the second baseline | the regression run completed (`regress.log`) and the ANSI run completed with its comparison (`ansi.log`); `doc/wasm-port/baselines/sprint-9.txt` written with the files, the failing tests and the ANSI results; fewer files fail than in the first baseline (60 against 108); no regression file dies of a trap the sprint fixed |
| regressions (Sprint 9) | `compile-file`, `load`, `disassemble`; `(require :sb-md5)`; `run-program` through the host |
| regressions (levels 0 and 1) | level-0: 16 checks; level-1: 444 argument sets, 0 failures |

## The baseline runs

Both suites ran on the build of commit `bfba752` plus the fixes of the
same working tree (the `vm.max_map_count` limit raised to 1,048,576 for
the run, as the manual says).

| Run | Result | Time |
|---|---|---|
| `tests/wasm-parallel-exec.sh -j 3`, `SBCL_WASM_TEST_TIMEOUT=900` (`regress.log`) | 403 files, 343 passed, 60 did not; 167 unexpected failures by name, 6,958 successes | 58 min (with the ANSI run and the diagnostics sharing the machine) |
| `tests/ansi-tests.sh` (`ansi.log`, `tests/ansi-test/results.txt`) | 21,752 tests, 21,543 pass, 205 fail, 4 crashed, 13 processes; 62 failures outside the expected list | 15 min |
| the fixed files alone, before the C stack fix (`/tmp` logs, `develop.md` section 8) | 14 of 26 files pass that all failed in the first baseline | |

The report: `doc/wasm-port/baselines/sprint-9.txt` (`baseline.sh
regress.log tests/ansi-test/results.txt`). The logs are local files
(`*.log` is ignored by the repository).

## Checked by hand, not in the script

- The bisection of the ANSI state issue (`ansi-bisect.lisp`,
  `ansi-diag.lisp`; `develop.md`, section 9): the generator's answer
  changes after test 1,251 of a run and not with that test alone.
- `(sb-c::compile-perfect-hash (sb-c:make-perfect-hash-lambda keys) keys)`
  on 300 random key sets, 8,000 calls on one set, and calls interleaved
  with forced collections: no failure in a fresh process.
- Two concurrent test processes get different pids; `save-lisp-and-die`
  from the saved core (`init.test.sh`, `save1.test.sh`) passes under
  the runner.
- `exhaust.impure.lisp` under the new host: "call stack exhausted", the
  process ends with a trap instead of the host's abort; the Lisp-level
  `storage-condition` remains open.
