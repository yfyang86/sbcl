# Sprint 13 — test record

The build under test: the tree at the merge commit, built by
`./build-wasm.sh lisp opt runtime warm contrib` (the register cache,
the parameters, the inline allocation, the optimized cold module;
`obj/wasm-build/lisp-s13g.log`), the runtime `src/runtime/sbcl.wasm`
with the collector's root fix, under the Wasmtime host. The earlier
cores of the sprint (`develop.md`, section 4) are the same tree's
builds before the last two fixes.

## 1. Levels 0 and 1

`./build-wasm.sh --fast test` at each build (the after-xc core rebuilt
for the changed compiler): level 0, 16 checks; level 1, 163 cases,
444 argument sets. Green on every build but two, each of which taught
something (`develop.md`, section 3):

- s13d, the first build with the parameters: 0 of 444, "type mismatch
  with parameters" — the level-1 rig had not been rebuilt for the new
  function type. `build-wasm.sh host` builds the rig now.
- s13e, a `return` writing the parameter registers of its mask
  regardless of use: 442 of 444, `more-arg-values` returning its first
  argument instead of the sum. The case that decided the mask rule.

## 2. The regression suite

`./build-wasm.sh --jobs 2 regress` (`tests/wasm-parallel-exec.sh`,
one process per file): 403 files.

| Run | Files failed | Unexpected failures (tests) |
|---|---|---|
| Sprint 12's baseline (`doc/wasm-port/baselines/sprint-12.txt`) | 55 | 154 |
| s13f (the parameters, before the two fixes) | 55 | 153 |
| s13g (the final build; `doc/wasm-port/baselines/sprint-13.txt`) | (section 5) | (section 5) |

The differences from Sprint 12's baseline, each examined:

- **`block-compile.impure.lisp`** passes (it died reporting an expected
  failure in Sprint 11's and 12's cores); the cached code changed
  nothing there on purpose, and the file is watched for its return.
- **`compiler-2.impure.lisp / EVAL-TOP-LEVEL-CODE-SEPARATE-COMPONENT`**
  passes.
- **`save7.test.sh`**, new in s13f: `save-lisp-and-die` from the saved
  core with a 260 MB heap exhausted it during the save's collection.
  Every save re-lowered the warm load's seven thousand blobs into a
  module (200 MB of garbage); with the cached code a third bigger the
  test's heap no longer absorbed it. A save that loaded nothing since
  the last merge skips it now (`develop.md`, section 5); the test
  passes on s13g.
- Every other failed file and every failing test is the baseline's
  (the diff of the two reports, normalized, is empty but for the
  three above).

## 3. The ANSI suite

`./build-wasm.sh ansi` (`tests/ansi-tests.sh`, one test per process,
the suite's core rebuilt from `output/sbcl.core`):

| Run | Tests | Failures | Crashed | Unexpected |
|---|---|---|---|---|
| Sprint 12's final run | 21,752 | 135 | 4 (the `INVOKE-DEBUGGER` four) | 0 |
| s13f | 21,752 | 136 | 4 (the same) | 1: `FORMAT.E.26` |
| s13g | (section 5) | | | |

`FORMAT.E.26` formats twenty random floats with `~E` and compares
the rounding with its own; it fails now and then on every SBCL, and
upstream's `ansi-tests.sh` leaves it out of the failing set before the
comparison. The port's comparison (`tests/wasm-ansi-tests.sh`) does
the same now. It passed in Sprint 12's run and in this sprint's
second.

## 4. cl-bench

`tests/wasm/bench/cl-bench-compare.sh`, scale 10, a 1 GB heap
(`develop.md`, sections 4 and 6; the tables in
`doc/wasm-port/baselines/sprint-13-cl-bench.md`): the register cache
and the inline allocation 1.47 on the geometric mean of 62 benchmarks
against Sprint 12's optimized core, the parameters nothing measurable
on top (0.98 against the build before them). Against the host SBCL
the port is 5.9× slower on the whole suite.

The compute-bound subset at scale 1 (the original run counts) is the
run that found the collector's root bug: it died in `bitvectors`
after the other kernels on every core of the sprint and ran clean on
Sprint 12's. With the fix it runs to the end (31 kernels), and the
same run is the sprint's measurement against the host (section 5).

## 5. The final runs

(the s13g core: filled in below)

## 6. Checked by hand

- The cached code: `disassemble` of a two-argument function shows the
  prologue loads, the locals, the flush before and the reload after
  its `call_indirect`, the five parameters pushed before the entry
  index (`develop.md`, section 4).
- The cold core boots and the warm load runs on every build whose
  levels were green — and on s13d, whose levels were green only
  because the rig was stale; the cold core died in `hashset-insert-if-absent`
  and pointed at `identity`.
- The GC root fix: the four-kernel reproducer
  (`fft mandelbrot/complex mandelbrot/dfloat bitvectors`, scale 1)
  fails in under a minute on the s13f core with the old runtime and
  passes with the fixed one; so does the 31-kernel subset.
- The save fix: `save-lisp-and-die` from `output/sbcl.core` with a
  260 MB heap, which exhausted the heap before, writes the core.
