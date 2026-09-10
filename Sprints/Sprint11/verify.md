# Sprint 11 — verification and further study

## 1. Exit criteria (the second half of the plan's "Sprint 9–10: triage and fix")

The plan's exit for the pair of sprints: zero unexpected failures in
both suites, the skip list under 150 forms with reasons, the CI job
running both suites. This sprint ran neither suite in full (the
sprint's instruction), so the criteria are checked on the targeted runs
of `test.md` and the one-process ANSI run, and the full runs are the CI
job's or the next sprint's.

| Criterion | Result |
|---|---|
| the one cause behind 55 ANSI failures (the generator's changing answer) | the failures are gone in this build: the whole suite in one process, 21,752 tests, 146 failures, all in the expected list but four that are the one-process run's own (`develop.md`, section 1); the stray write's victim moved with the runtime's layout and the writer was not identified: on the backlog with two detectors that cost nothing when off |
| executable cores (`banner`, `save6`, `save7`) | met: a launcher script with the core appended; the three files pass; a double dereference in `FOREIGN-SYMBOL-SAP` found and fixed on the way |
| a control-stack guard (`exhaust`) | met: explicit limits checked by the compiled code at every frame allocation and binding, the runtime's guard handler, `storage-condition` in the handler and restored after; `exhaust.impure.lisp` passes |
| timers through the host (`timer`, `with-timeout`, deadlines) | met: the runtime's deadline, the host's epoch tick, the safe point's delivery with deferral, sleeps cut at the deadline, and a safe point at every loop back edge so a loop without calls sees the timer; `timer.impure.lisp` and `deadline.impure.lisp` pass (the deadline tests that wait on a child are tagged: nothing interrupts the host's wait) |
| merging the saved modules (startup, mapping count) | met: one module per saved core (`wasm-merge-loaded-modules`), 7,138 modules before |
| the CI job `linux-wasm.yml` | written: tool chain, host, cross build, runtime, warm load, contribs, levels 0–1, both suites; it has not run on GitHub from this tree |
| the smaller items | `poll` on a file (a regular file is always ready), `file-author` without a user database; the `arith-2` arithmetic bugs and `INVOKE-DEBUGGER.1` under `--disable-debugger` remain |
| the skip list under 150 forms with reasons | `:skipped-on :wasm` forms: see `test.md` (the count of the tree); every one carries a reason |

## 2. What the sprint taught

- **The evaluator is a second compiler.** `save7.test.sh` failed on a
  value compiled code read correctly; the forms came from stdin and
  went through `SIMPLE-EVAL-IN-LEXENV`, which calls
  `FOREIGN-SYMBOL-SAP` as a function. Every VOP with a function
  counterpart is two implementations of one contract, and the port had
  changed the contract (`FOREIGN-SYMBOL-ADDRESS` returning the cell's
  content) on one side.
- **Guards without pages are limits plus a poll.** The guard-page
  design (fault, unprotect, handler, reprotect on return) maps onto a
  limit word, a compare at the points that move the stack pointer, and
  the interrupt-pending word's polling to notice the return. The same
  safe point serves the collector, the host's interrupt, the timer and
  now the guards; making it fire at loop back edges too was the
  missing piece for anything that needs to interrupt a computation.
- **A signal is two things on this target.** The timer's expiry has to
  reach code that is running (the host's epoch tick, seen at a safe
  point) and code that is blocked in the host (the sleep cut into
  slices; a `run-program` wait cannot be cut). Deferral under
  `WITHOUT-INTERRUPTS` falls out of `*interrupt-pending*` and the exit's
  `RECEIVE-PENDING-INTERRUPT` being the same import.
- **A layout-dependent bug is not fixed by disappearing.** The
  generator failures vanished with a relink; the records say so rather
  than claiming a fix, and the detectors (the null-page canary checked
  after every collection, the watch) are in place for its return.
- **`poll` is not one thing on WASI either.** wasi-libc's `poll` works
  on files and fails on the standard descriptors under Wasmtime; its
  `select` the other way round. The port keeps `select` and answers for
  regular files itself.

## 3. Open items (the backlog, in order of tests affected)

1. **Debugger support**: frame walking for `backtrace`, `sb-di` frames,
   `error-context`, `restart-frame`, `return-from-frame`, stepping
   (`debug.impure`, `backtrace`, `step`).
2. **`dynamic-extent`**: stack allocation in the backend
   (`dynamic-extent.pure`, `mop`, `condition`, `reader`, `pathnames`).
3. **The writer of the nested internal error pairs** (`develop.md`,
   section 1): reproduce with `SBCL_WASM_CANARY=1` on a long run, then
   `SBCL_WASM_WATCH` on the first address that changes.
4. **`run-program :wait nil` and `:stream`** (the deadline tests that
   wait on a child, `run-program`, `external-format`'s
   `:invalid-external-format`): a host import that starts a child and
   one that polls it.
5. **Arithmetic** (`arith-2`: `:signed-byte-8-p-unsigned`,
   `:truncate-unknown-integer`, `:word-floor-ceiling`,
   `:logand-cut-constants.2`), `float-2` (`bug-407`,
   `bignum-double-float-overflow`), the collector items (`gc.impure`,
   `hash-2` weakness, `finalize`), the `hopscotch` mismatch.
6. **`INVOKE-DEBUGGER.1` under `--disable-debugger`** (four expected
   ANSI crashes) and the `FILE-LENGTH.ERROR.3` entry that passes now.
7. **Releasing the modules of dead code**: the blobs and the table
   entries of code the collector freed stay (the one-module save keeps
   the count of instantiations at one; the memory is the remaining
   cost).
8. Carried: the one-off trap at the end of a warm compile (Sprint 8),
   the 512 MiB default heap.

## 4. Further study

- The back-edge poll's cost: a load and a branch per loop iteration in
  every function. The level-1 rig's timing and the warm load's time
  (before: about 8 minutes) are the measures; a cheaper scheme would
  poll every N iterations, or only in loops the compiler cannot bound.
- The merged module's compile time at startup: one module of a warm
  load's size is compiled once by Wasmtime and cached; the first start
  after a save pays it. Measure against the 7,138 small modules.
