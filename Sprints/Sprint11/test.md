# Sprint 11 — test record (targeted runs, no UAT)

The sprint's instruction: neither hour-long suite and no UAT script.
Each item was validated on the test files it concerns, under the
regression runner (`tests/wasm-parallel-exec.sh`, which runs
`tests/run-tests.sh` per file against `output/sbcl.core`), plus the
whole ANSI suite in one process as the check of the state issue. The
build under test: the sprint's last full rebuild (pass-1, pass-2, the
runtime, the warm load; `obj/wasm-build/rebuild-s11g.log`, then pass-2
and the warm load again for the timer queue, `rebuild-s11h.log`) of
the tree at the merge commit.

## 1. Regression test files

`tests/wasm-parallel-exec.sh -j 2` over the files each item concerns
(logs under `$SBCL_PAREXEC_TMP`); a file passes when every test in it
passes or is skipped by its tag.

| File | Item | Result |
|---|---|---|
| `exhaust.impure.lisp` | the stack guards | passes (`:basic`, `:non-local-control`, `:restarts`, `:binding-stack`; the Windows-only and alien-stack tests skipped by their own tags) |
| `timer.impure.lisp` | timers, the loop safe point | passes, all 16 tests (the deferrables tests, relative and absolute timers, repeat and unschedule, the stress tests, `with-timeout`, `schedule-stress`, `catch-up`) |
| `deadline.impure.lisp` | deadlines | passes (the five tests waiting on a child process tagged: no-fork) |
| `banner.test.sh`, `save6.test.sh`, `save7.test.sh` | executable cores, `foreign-symbol-sap` | pass |
| `external-format.pure.lisp` | `poll` on files and devices | passes (`:end-of-file`; `:invalid-external-format` tagged: `run-program :stream`) |
| `filesys.pure.lisp` | `file-author` | passes (`(file-author stringp)` tagged: no user database) |
| `loop.pure.lisp`, `arith.pure.lisp`, `hash.pure.lisp`, `print.impure.lisp` | the loop safe point, the one-module core, the pure-test state check | pass |

The first runs of this set found, and the sprint fixed: the pure-test
global-state check tripping on `*wasm-code-blobs*`; a saved core whose
first symbol lookup trapped (the modules of code compiled after the
merge); `timer.impure.lisp` hanging in a call-free loop (the loop safe
point); a timer unscheduling itself hitting a recursive scheduler lock;
`SLEEP.2-13` losing `sb_nanosleep_float` to an `#ifdef`.

## 2. The ANSI suite in one process

`Sprints/Sprint11/ansi-oneproc.lisp` in the suite's saved core
(`tests/wasm-ansi-tests.sh` builds it from `output/sbcl.core`): every
pending test in one process, the `INVOKE-DEBUGGER` tests left out.

Result on the final core: 21,752 tests, 137 failures, compared
with the expected-failure list of `ansi-tests.sh` (its `#+wasm` entries
included, before this sprint's trimming of that list): 3 failures
outside the list, all the one-process run's own (`FORMAT.E.26`, which
`ansi-tests.sh` itself discounts; `LOAD-PATHNAME.1` and
`LOAD-TRUENAME.1`, from the changed default directory), and 13 entries
of the list passing: `FILE-AUTHOR.1-7`, `LISTEN.7` and
`FILE-LENGTH.ERROR.3`, which this sprint removed from the `#+wasm`
entries, and the four `INVOKE-DEBUGGER` tests this run leaves out. The
55 state-dependent failures of the second baseline do not occur
(`develop.md`, section 1). An earlier run of the same check on a
previous build of the sprint found `SLEEP.2-13` failing
(`sb_nanosleep_float` lost to an `#ifdef`, fixed) and, before that, the
suite refusing to load (the stale fasls, `develop.md` section 4).

## 3. Levels 0 and 1

`./build-wasm.sh test` (the after-xc core rebuilt for the changed
assembler): level 0, 16 checks; level 1, 444 argument sets, 0 failures.
The first run failed all 31 catch/throw cases: the rig had never
resolved the C-stack helper fixups of Sprint 10 (a stale after-xc core
had hidden it); the mini-runtime now fills two cells for them.

## 4. Checked by hand

- The stack guard: `(handler-case (f 0) (storage-condition (c) ...))`
  for a runaway recursion answers `CONTROL-STACK-EXHAUSTED` twice in a
  row in one process (the guard restored in between); before the
  sprint the same recursion wrote through hundreds of megabytes and
  ended in Wasmtime's "call stack exhausted" trap.
- Timers (`Sprints/Sprint11/timer-probe.lisp`): a timer fires during
  a sleep (0.3 s into a 1 s sleep), during a busy loop (at 0.301 s) and
  `(with-timeout 0.3 (sleep 2))` signals `TIMEOUT`; `with-deadline`
  around a sleep signals `DEADLINE-TIMEOUT`.
- Executable cores: `obj/wasm-build/exe-test` (a launcher with the
  core appended) starts, `*posix-argv*` names it, `--version` and the
  saved runtime options apply; `save7.test.sh`'s memory-size
  assertions read the C variables through the evaluator.
- The one-module save: `output/sbcl.core` after the warm load holds
  4 modules (the merged one of 7,132 blobs, 14,266 functions, and three small ones for the code compiled on the way to the file) (before the sprint: 7,138 modules); it starts and runs
  the test files above.
- `file-author` answers `NIL`; `listen` on a file stream at its start
  answers `T` (`LISTEN.7`'s case).
- The skip list: 139 `:skipped-on :wasm` forms and file skips in
  the tree, each with a reason in a comment.

## 5. Not run

The regression suite (`./build-wasm.sh regress`) and the ANSI driver's
one-test-per-process run (`./build-wasm.sh ansi`), and the UAT script
(none written this sprint). The CI job `linux-wasm.yml` runs both
suites on push; the next sprint's baseline is the next full run.
