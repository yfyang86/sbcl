# Sprint 10 — verification and further study

## 1. Exit criteria (this sprint's half of the plan's "Sprint 9–10: triage and fix")

| Criterion | Result |
|---|---|
| every baseline failure classified (backend, runtime, unsupported, no-float-traps, timing or depth, upstream-expected) | met: `triage.md`, 108 files and the ANSI groups, each with its class and action |
| the classes that killed test processes fixed | met: foreign calls (undefined aliens, wasi-libc gaps, `sb_nanosleep`), the empty-arm `unreachable`, saving a core under another name, the host's native stack, the C shadow stack across non-local exits, the bit-vector store mask (`develop.md`) |
| the unsupported tests carry `:skipped-on :wasm` with a reason; the `#+wasm` ANSI expected-failure list | met: `no-signals`, `no-breakpoints`, `no-fork`, `no-dlopen`, `depth`, the blocklisted contribs; `ansi-tests.sh`'s list with the port's entries, compared by the driver |
| the second baseline report lists what remains | met: `doc/wasm-port/baselines/sprint-9.txt` (403 files: 343 passed, 60 did not, against 295 and 108 in the first baseline; 6,958 successes against 5,520; no file dies of a foreign-call or `unreachable` trap; ANSI: 21,752 tests, 21,543 pass, 205 fail, 4 crashed (the `invoke-debugger` tests, by design), in 13 processes against 48; 62 failures outside the expected list, 55 of them the state-dependent group of `develop.md`, section 9) |

The plan's exit for the pair of sprints (zero unexpected failures in both
suites, the skip list under 150 forms with reasons, the CI job) is the
next sprint's.

## 2. What the triage taught

- **One cause, many files.** 23 of the 108 files died of foreign calls,
  and behind them were three defects: a generator that declared every
  name `void (void)`, a `void` function declared `int`, and names the
  table did not keep. Eight files and five ANSI tests died of one
  off-by-one in the function assembler's arm split. Twelve shell tests
  died of the missing module copy at save time. The report's list of
  108 was a list of about ten problems.
- **A typed table is a strict linker.** Every mismatch between a Lisp
  `define-alien-routine` and its C prototype that machine targets
  tolerate (a `void` function read as `int`, a stub of another type) is
  a trap here. The guard entry and the `CALL-OUT` check turn the
  undefined case into a Lisp error; the mistyped case remains a trap
  and is found by the trap's top frame (`wasm-coreindex.py`).
- **State-dependent failures were a leak.** The 55 ANSI failures that
  passed one at a time and failed in the run were the C shadow stack,
  spent by twenty thousand non-local exits through C frames: a small
  leak per error, invisible until a long run. `c_stack_save` at the
  block, `c_stack_restore` at the entry.
- **The runner's process boundary hides classes.** A file that dies is
  one line in the report whatever happened inside; the per-file logs,
  the last `::: Running` line and the trap kind are what to classify
  by, which `baseline.sh` now shows for each file.

## 3. Open items (the next sprint's backlog, in order of tests affected)

1. **Debugger support**: frame walking for `backtrace`, `sb-di`
   frames, `error-context`, `restart-frame`, `return-from-frame`,
   stepping (`backtrace`, `unwind-to-frame-and-call`, `step`,
   `defstruct`'s "uninitialized slot" message, `debug.impure`).
2. **`dynamic-extent`**: stack allocation in the backend
   (`dynamic-extent.pure`, `mop`, `condition`, `reader`, `pathnames`).
3. **Module exhaustion**: merge the saved modules at save time and
   release the modules of dead code (`arith-slow`, `cmp-combinations`,
   `compiler-2`, `seq.impure`, `save4.test.sh`); until then
   `vm.max_map_count` is raised for the suites (the manual).
4. **Executable cores** (`banner`, `save6`, `save7`): a launcher with the
   core appended, or the host running a file with an embedded core.
5. **Timers and signals** through the host (`setitimer`, `with-timeout`,
   deadlines; `timer`, `signals`, the tagged tests): the pending-interrupt
   word already carries Ctrl-C and the deadline.
6. **A control-stack guard**: `storage-condition` on exhaustion instead
   of a trap at the top of the memory (`exhaust`).
7. **`poll`/`select` on files** (`listen`, `external-format`'s
   `:end-of-file`), `run-program :wait nil` and `:stream`
   (`run-program`, `external-format`), `file-author` (no user database).
8. **Arithmetic** (`arith-2`: `:signed-byte-8-p-unsigned`,
   `:truncate-unknown-integer`, `:word-floor-ceiling`,
   `:logand-cut-constants.2`), `float-2` (`bug-407`,
   `bignum-double-float-overflow`), the collector items (`gc.impure`,
   `hash-2` weakness, `finalize`), the remaining `hopscotch` mismatch,
   and the files listed "to look at individually" in `triage.md`.
9. Carried: the one-off trap at the end of a warm compile (Sprint 8),
   the 512 MiB default heap, the safe point only at function entry.

## 4. Further study

- The trap classes are exhausted by a fixed procedure: trap kind, last
  test started, top frame's function (core) or the dumped module's
  offset (run time). `baseline.sh` prints the first two; making the
  runner dump the installed modules on a trap (`SBCL_WASM_DUMP_INSTALLED`
  is already there) would give the third without a rerun.
- The C shadow stack fix makes the C frames between Lisp frames
  consistent again after an exit, but the *Lisp* number stack (NSP) and
  the binding stack are restored by the existing unwind code; a test
  that mixes `alloc-number-stack-space` with a non-local exit through a
  foreign call would confirm both.
