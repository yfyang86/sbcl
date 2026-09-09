# Sprint 10 — triage and fix, part one

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 9–10:
triage and fix" (the directory numbering is one ahead of the plan; this
sprint is the plan's Sprint 9, the first of the two).

Goal: classify every failure of the first baseline
(`doc/wasm-port/baselines/sprint-8.txt`): backend bug (fix), runtime bug
(fix), unsupported by design (`:skipped-on :wasm` with a one-line
reason), floating-point traps (`:no-float-traps`), timing or depth
(`:broken-on :wasm` with an issue); fix the classes that kill a test
process (foreign calls, the `unreachable` traps, saving a core); add the
`#+wasm` expected-failure list to `tests/ansi-tests.sh`.

Exit criterion (this sprint's half of the plan's): every baseline
failure is classified in `triage.md`; no file of the regression suite
dies of a trap that a fix in this sprint covers; the unsupported tests
carry their tags; the second baseline report
(`doc/wasm-port/baselines/sprint-9.txt`) lists what remains for the
next sprint, whose exit is zero unexpected failures in both suites and
the CI job.

Status: done. The second baseline report is
`doc/wasm-port/baselines/sprint-9.txt` (the regression suite: 403 files,
343 passed, 60 did not, against 295 and 108 before; the ANSI suite:
21,543 pass, 205 fail, 4 crashed, 62 outside the expected list, 55 of
them one state-dependent cause that heads the next sprint's list).
Records: `triage.md`, `develop.md`, `test.md`
(UAT), `verify.md`; script: `uat.sh`. The sprint branch `sprint10` is
merged into `wasm-dev` with `--no-ff` once `uat.sh` is green.
