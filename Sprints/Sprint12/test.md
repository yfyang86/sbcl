# Sprint 12 — test record

The build under test: the tree at the merge commit, built by
`./build-wasm.sh lisp opt runtime warm contrib` (the stackifier, the
optimized cold module; `obj/wasm-build/rebuild-s12b.log`), the runtime
`src/runtime/sbcl.wasm` under the Wasmtime host. The comparison cores
of `develop.md`, section 5, are the same tree's earlier builds.

## 1. Levels 0 and 1

`./build-wasm.sh --fast test` (the after-xc core rebuilt for the
changed assembler): level 0, 16 checks; level 1, 444 argument sets, 0
failures (`obj/wasm-build/test-s12b.log`). The first run of the sprint
found the fall-through child needing a block (`develop.md`, section
1); the second, after the terminator note, passed with 34 fallbacks in
the after-xc compile (the same 34 as pass-2).

## 2. The regression suite

`./build-wasm.sh --jobs 2 regress` (`tests/wasm-parallel-exec.sh`,
one process per file): 403 files.

| Run | Files failed | Unexpected failures (tests) |
|---|---|---|
| Sprint 10's baseline (`doc/wasm-port/baselines/sprint-9.txt`) | 60 | 167 |
| this build, first run (stale contribs) | 63 | 216 |
| this build, final run (the disassembler fix, the contribs rebuilt) | 55 | 154 |

The first run's differences from the baseline, each examined:

- **Stale contribs** (`sb-aclrepl`, `sb-cltl2`, `sb-concurrency`,
  `sb-md5`, `sb-rotate-byte`, `init.test.sh` and the 23 `xref`
  failures of `sb-introspect`): the contrib fasls of the Sprint 11 core
  loaded into the new one ("invalid number of arguments", a trap, a
  type error in `find-definition-sources-by-name`). `./build-wasm.sh
  contrib` and all pass but `sb-introspect`, which fails where the
  baseline fails (alien callbacks). The lesson of Sprint 11's stale
  ANSI fasls again: a rebuilt core needs its contribs rebuilt.
- **`mop.impure.lisp / CHANGE-CLASS-TEMP-ON-STACK`**:
  `stack-allocated-p` of an object the port allocates on the heap
  (no dynamic-extent allocation, the backlog); it passed in the
  baseline by the accident of the heap's layout. Tagged
  `:skipped-on :wasm` with the reason.
- **`block-compile.impure.lisp`**: the file dies in
  `CLASSOID-PROPER-NAME` given `(SATISFIES SIMPLE-FUN-P)` while
  reporting the expected failure of
  `:block-compile-top-level-closures.same-environment.local-calls`.
  The same on Sprint 11's core (`TEST_SBCL_CORE=obj/wasm-build/sbcl-s11.core`),
  whose full suite never ran: not the stackifier's; on the backlog
  (`verify.md`).
- **`format.pure.lisp / CACHED-TOKENIZED-STRING`**: "expected not to
  cons, 98,304 bytes in 10,000 runs": fails on Sprint 11's core and on
  the optimized-module core, passes on the plain stackified core; a
  collection during the measured runs moves the bytes-consed count by
  the size of the allocation region. Noise of the measurement, not
  of the code.
- **`disassem.impure.lisp / DISASSEMBLE-MACRO`**: new, and real: the
  first build's disassembler still assumed table slot `i` holds
  function `base + i`, which `wasm-opt`'s function merging breaks
  (`develop.md`, section 4); the fix (the element segment) was in the
  tree but not in that core. Verified on the rebuilt core by hand:
  `(disassemble 'car)` names `CAR`; `(disassemble 'and)` prints.
- Passing now, failing in the baseline: `deadline`, `filesys`,
  `sleepytests`, `print` (Sprint 11's work), `compiler-2 /
  EVAL-TOP-LEVEL-CODE-SEPARATE-COMPONENT`, `compiler.pure /
  POSITION-DERIVE-TYPE-OPTIMIZER`, the two `stream.pure` tests,
  `external-format.pure`, `lzcore.test.sh`.

## 3. The ANSI suite

`./build-wasm.sh ansi` (`tests/ansi-tests.sh`, one test per process,
the suite's core rebuilt from `output/sbcl.core`):

| Run | Tests | Failures | Crashed | Unexpected |
|---|---|---|---|---|
| first run of this build | 21,752 | 135 | 4 (the `INVOKE-DEBUGGER` four) | 1: `FILE-LENGTH.ERROR.3` |
| final run | 21,752 | 135 | 4 (the same) | 0 |

`FILE-LENGTH.ERROR.3` passed in Sprint 11's one-process run, which
took it off the `#+wasm` expected list; in the one-test-per-process
run it fails as it did before Sprint 11. Back on the list with that
note: its outcome depends on what ran before it in the process.

## 4. cl-bench

`tests/wasm/bench/cl-bench-compare.sh` on the three cores and the host
(`develop.md`, section 6; the tables in
`doc/wasm-port/baselines/sprint-12-cl-bench.md`): the stackifier 1.18
on the geometric mean of 62 benchmarks against the dispatch loop,
`wasm-opt` 1.01 on top, the optimized build 8.2× slower than the host
SBCL on the same machine.

## 5. The final runs

On the core of the rebuild with the disassembler fix and its contribs
(`obj/wasm-build/regress-s12b.log`, `ansi-s12b.log`;
`doc/wasm-port/baselines/sprint-12.txt` is the regression baseline):

- Regression suite: 403 files, 55 did not pass (Sprint 10's baseline:
  60), 154 unexpected test failures (167). Against the baseline's
  test list the only additions are `block-compile.impure.lisp`
  (section 2: on Sprint 11's core too) and the two tests whose names
  carry a scratch file's name (`SPLAT-NIL`,
  `DISASSEMBLE-ANNOTATE-FUNS`: the same tests, a different temporary
  name). `DISASSEMBLE-MACRO` and `CACHED-TOKENIZED-STRING` pass; the
  contrib files pass but `sb-introspect`, as in the baseline.
- ANSI suite: 21,752 tests, 135 failures and 4 crashes, all on the
  expected list; 0 unexpected, 0 expected-but-passing.

## 6. Checked by hand

- The stackified code: `(disassemble 'car)` on the plain core shows
  the body as nested `block`s with `br_if`, no `br_table`, no `$pc`
  stores; on the optimized core the same, with the merged functions'
  names from the name section.
- The safe point in loops: `timer.impure.lisp` and
  `deadline.impure.lisp` pass in the suite (the back-edge poll under
  the structured `loop`).
- The fallback count: `grep -c "stackify:"` on `pass-2.log` (34) and
  `warm-compile.log` (61); the names and files in `develop.md`,
  section 3.
- The opt step is idempotent (`wasm-core.wasm.orig` present: skipped)
  and pass-2 removes both files.
