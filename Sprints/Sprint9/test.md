# Sprint 9 — test record (UAT)

`uat.sh` (full mode: `build-wasm.sh host`, pass-1, pass-2, the runtime
and the warm load from scratch, the routing checks, `run-program`
through the host, `compile-file`, `load` and `disassemble`, the
contribs, the two test suites and the baseline report, the Sprint 8
checks, level 0, the after-xc core and level 1; about two and a half
hours, most of it the suites). `UAT_FAST=1` skips the Lisp builds and
the warm load and checks their products; `UAT_SKIP_SUITES=1` skips the
two suites (their logs from the baseline runs are checked instead, and
the report must exist). Output: `uat-output.txt`; logs and probe
outputs next to it.

Result: **28 checks passed, 0 failed** (`uat-output.txt`, fast mode without the
suites, on the products of the sprint's builds and the baseline runs).
A first pass (`uat-output-run1.txt`, 24 passed, 4 failed) found one
stale product and three defects of the script: the saved core had been
built before the public-features fix (`make-target-2-load.lisp`, so
`:wasm32` and `:wasi` were missing from `*features*`; the warm load
was rerun), the disassembly check looked for `call_indirect` in the
body of `car`, which has none (it now looks for `i32.load` and
`call`), and the `require` checks read `sb-md5:` and `asdf:` in the
same form as the `require` (two `--eval`s now). The script was corrected
and rerun.

| Group | Checks |
|---|---|
| toolchain | wasi-sdk present; `sbcl-wasm` builds with `run_process` |
| Lisp side, runtime, warm load | the build products (`xc.core`, `wasm.core`, `wasm-core.wasm`, `sbcl.wasm`, `output/sbcl.core`, `output/sbcl-core.wasm`); the linkage table has `wasm_run_process`, `environ`, `sysconf` |
| routing | `run-sbcl.sh` runs the saved core through `sbcl-wasm`, `*default-pathname-defaults*` and `*runtime-pathname*` are the host's paths, `:wasm32` and `:wasi` are in `*features*`; `tests/subr.sh`'s `run_sbcl` routes through the wrapper from `tests/` |
| `run-program` through the host | exit codes, captured and merged output, a stream as input, a child runtime (`(run-program *runtime-pathname* ...)` exits 7); the child gets the runtime's environment after `setenv` from Lisp |
| `compile-file`, `load`, `disassemble` | a file compiled by the saved core, loaded and called (`fib 15` = 610); `disassemble` prints a loaded function (the run-time module at its table base) and a core function (`car`, in the core module) |
| contribs | the ten fasls in `obj/sbcl-home/contrib`; `(require :sb-md5)` and `md5sum-string`; `(require :asdf)` and `asdf-version` |
| the suites and the baseline | the regression run completed (`regress.log`, 403 files) and the ANSI run completed (`ansi.log`, `progress.txt` = DONE); the report lists the files, the failing tests and the ANSI results |
| regressions (Sprint 8) | `--eval '(print (+ 1 2))'`; CLOS in the saved core |
| regressions (levels 0 and 1) | level-0: 16 checks; level-1: 444 argument sets, 0 failures |

## The baseline runs

Both suites ran on the saved core built from the sources of `cc92072`
(before the public-features change of `26412eb`: the two keywords in
`*features*` are the only difference to the core the UAT checked, and
no test file conditionalizes on them), with the runtime and host of
`4975fd4` (the pid fix).

| Run | Result | Time |
|---|---|---|
| `tests/wasm-parallel-exec.sh -j 3`, `SBCL_WASM_TEST_TIMEOUT=900` (`regress.log`) | 403 files, 295 passed, 108 did not; 161 unexpected failures by name, 5,520 successes | 44 min |
| the same before the pid fix (`regress-run1.log`) | 122 files did not pass: 15 of them (the `mop-*.impure-cload` files, `iso-8859-*`, `package-locks`, `save10`, `save11`, `room`, `autoclose-stream`) were the scratch-file collisions of `develop.md`, item 11; `genheaders.test.sh` failed only in the second run (`verify.md`, class 3) | 60 min (the `timer` file ended by hand at the end) |
| `tests/ansi-tests.sh` (`ansi.log`, `tests/ansi-test/results.txt`) | 21,752 tests, 21,539 pass, 192 fail, 21 crashed, in 48 processes (one restart per crash, each crashed test retried once) | 20 min, plus 1 min to load the suite and save `wasm-ansi.core` |

The report: `doc/wasm-port/baselines/sprint-8.txt` (`baseline.sh
regress.log tests/ansi-test/results.txt`).

## Timings

| Step | Time |
|---|---|
| host build (with `run_process`, `process_id`) | 1 min |
| runtime relink | 1 min |
| warm load (compile phase, 68 files) and save | 8 min |
| `./build-wasm.sh contrib` (eleven contribs) | 3 min |
| the saved core to `--eval` and exit | 3.5 s |
| a run-tests.sh file: a pure file / an impure file with its child | 7–15 s / 12–20 s |
| the ANSI suite's saved core to the first test | 4 s |

## Checked by hand, not in the script

- The six ANSI tests that crash reproduce one at a time in
  `wasm-ansi.core` (`(rt:do-test 'cl-test::sleep.1)` and the others):
  three `indirect call type mismatch` traps in `nanosleep`,
  `uid-username` and `unix-gethostname`, three `unreachable` traps in
  the tests' compiled code (`verify.md`, section 2).
- Runtime options after a toplevel option are ignored by the runtime
  (`develop.md`, item 10): `--noinform --core X` says "Can't find
  sbcl.core"; `--core X --noinform` runs.
- `sb-unix:unix-getpid` in the saved core returns the host's pid
  (`develop.md`, item 11); two concurrent runtimes get different ones.
