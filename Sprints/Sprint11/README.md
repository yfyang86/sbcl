# Sprint 11 — triage and fix, part two

Plan reference: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 9–10:
triage and fix" (the directory numbering is one ahead of the plan; this
sprint is the plan's Sprint 10, the second of the two).

Goal: work the backlog the first triage left (`Sprints/Sprint10/verify.md`,
section 3), starting with the one cause behind 55 ANSI failures (the
C perfect-hash generator's answer changes after some 1,250 tests in
one process), then the runtime items that block whole test files:
executable cores, a control-stack guard, timers through the host,
merging the saved modules; the CI job `linux-wasm.yml`.

Exit criterion: the plan's exit for the pair of sprints is zero
unexpected failures in both suites, the skip list under 150 forms with
reasons, and the CI job running both suites. This sprint runs neither
the hour-long suites nor the UAT (the sprint's instruction): each fix
is validated on the test files it concerns, the records say what was
verified how, and the suites' next full run is the CI job's or the next
sprint's.

Status: in progress. Records: `develop.md`, `verify.md`, `test.md`
(targeted runs, no UAT). The sprint branch `sprint11` is merged into
`wasm-dev` with `--no-ff` when its records are complete.
