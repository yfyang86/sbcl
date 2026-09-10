# Sprint 11 — test record (targeted runs, no UAT)

The sprint's instruction: neither hour-long suite and no UAT script.
Each item was validated on the test files it concerns, under the
regression runner (`tests/wasm-parallel-exec.sh`, which runs
`tests/run-tests.sh` per file against `output/sbcl.core`), plus the
whole ANSI suite in one process as the check of the state issue. The
build under test: the sprint's last full rebuild (pass-1, pass-2, the
runtime, the warm load; `obj/wasm-build/rebuild-s11c.log`) of the
tree at the merge commit.

## 1. Regression test files

RESULTS-TABLE

## 2. The ANSI suite in one process

`Sprints/Sprint11/ansi-oneproc.lisp` in the suite's saved core
(`tests/wasm-ansi-tests.sh` builds it from `output/sbcl.core`): every
pending test in one process, the `INVOKE-DEBUGGER` tests left out.

ANSI-RESULTS

## 3. Levels 0 and 1

LEVEL-RESULTS

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
  MODULE-COUNT (before the sprint: 7,138 modules); it starts and runs
  the test files above.
- `file-author` answers `NIL`; `listen` on a file stream at its start
  answers `T` (`LISTEN.7`'s case).
- The skip list: SKIP-COUNT `:skipped-on :wasm` forms and file skips in
  the tree, each with a reason in a comment.

## 5. Not run

The regression suite (`./build-wasm.sh regress`) and the ANSI driver's
one-test-per-process run (`./build-wasm.sh ansi`), and the UAT script
(none written this sprint). The CI job `linux-wasm.yml` runs both
suites on push; the next sprint's baseline is the next full run.
