# Sprint 12 — verification and further study

## 1. Exit criteria (the plan's "Sprint 11: stackifier")

| Criterion | Result |
|---|---|
| `stackify.lisp`, design 2.5 encoding 2, the dispatch loop as the fallback for irreducible control flow | met: the structured encoding is the default for every function whose arm graph is reducible; the dispatch loop lowers the rest, reported per function |
| loop back-edge interrupt polls | met: the poll of Sprint 11 is emitted before a `br` to an open `loop` (a `br_if` becomes `if; poll; br; end`); `timer.impure.lisp` and `deadline.impure.lisp` pass |
| `wasm-opt` for the cold core | met: the `opt` step (`-O2 -g`, 26 s, 38.4 → 33.8 MB), binaryen pinned and downloaded by the tool-chain step, the CI job runs it; the disassembler follows the renumbering |
| both test suites still clean | met against the last full baseline (Sprint 10's, `test.md` sections 2, 3 and 5): the differences are the stale contribs (rebuilt), one test tagged for the dynamic-extent backlog, one measurement-noise test, and one file that fails on Sprint 11's core as well; the ANSI suite has one unexpected failure, a test whose outcome depends on the process's history, back on the expected list |
| cl-bench geometric mean improves by the factor S0.3 predicted | **not met**: 1.18 measured against about 2 predicted (`develop.md`, section 6). The prediction measured control flow alone; the port's compiled code spends most of its time in the register file in memory, the runtime's slow paths and generic arithmetic, none of which the stackifier touches. Recorded with the per-benchmark tables (`doc/wasm-port/baselines/sprint-12-cl-bench.md`) and the next measure named (register caching) |
| no function falls back to dispatch except the irreducible ones, counted in the build log | met: 34 in pass-2, 61 in the warm load, each a loop with two entries (`develop.md`, section 3); the false fall-through edges that made 9,164 functions look irreducible are gone |

## 2. What the sprint taught

- **The graph is only as good as its edges.** The stackifier was
  right from the first run; the 9,164 fallbacks were the graph's.
  A byte range that ends in `return` or in a call that never returns
  has no successor, and the assembler is the one that knows: the
  `:terminator` note costs a byte and removes a decoder. The
  non-returning call's continuation, which the native backends leave
  dangling into the next block, has to be closed with `unreachable`
  on a target whose validator reasons about fall-through.
- **Off-by-one attributions cost more than they save.** The first
  reading of the build log put the fallbacks in the wrong files
  (`octets`, `pack-iterative`); the probe on those files found nothing
  and the log's convention (a file's line follows its messages) had to
  be re-read. Attribute, then verify on one case before probing.
- **Measure what the prediction measured.** S0.3 timed loops and
  kernels in which control flow was the only cost; cl-bench times
  everything. The factor of 2 is real for the control flow and 1.18
  for the whole, and the benchmark driver now exists to measure the
  next change (the register file) the same way.
- **A rebuilt core needs everything rebuilt with it.** The ANSI fasls
  in Sprint 11, the contribs this sprint: the fasl format does not
  change, so stale ones load and fail in confusing ways (a trap, an
  argument-count error, a type error deep in a contrib). The build
  driver's `contrib` step is part of any rebuild that the suites
  follow.
- **Two builds cannot share a directory.** The after-xc core build and
  pass-2 both write `obj/xbuild/wasm/from-xc/`; run concurrently to
  save time, one died on the other's fasl.

## 3. Open items (the backlog)

1. **The register file in Wasm locals** between safe points
   (`02-design.md` 2.4, item 3): the next factor in cl-bench, with the
   driver of this sprint as the measure.
2. **The remaining fallbacks** (34 + 61): node splitting of the
   secondary entry, or a dispatch limited to a loop's entries, would
   keep the structured form in those functions.
3. **`block-compile.impure.lisp`**: dies reporting an expected failure
   (`CLASSOID-PROPER-NAME` given `(SATISFIES SIMPLE-FUN-P)`), on Sprint
   11's core too; the type-error printing path with a `satisfies`
   type is the place to look.
4. **`FILE-LENGTH.ERROR.3`**: passes after other tests ran in the
   process, fails alone; the `*mini-universe*` object whose
   `file-length` signals the wrong error in a fresh process.
5. Carried from Sprint 11: the debugger support (frame walking,
   stepping), dynamic-extent allocation (`mop`'s
   `CHANGE-CLASS-TEMP-ON-STACK` now tagged), the writer of the nested
   internal error pairs, `run-program :wait nil` and `:stream`, the
   arithmetic and collector items, releasing the modules of dead code,
   the one-off trap at the end of a warm compile, the 512 MiB default
   heap.

## 4. Further study

- `wasm-opt`'s function merging (43,542 → 40,789 functions on the
  dispatch-loop module) says a fifth of the functions are byte-for-byte
  duplicates: the XEP stubs and the trampolines of the calling
  convention. Emitting them once, at the Lisp level, would shrink the
  module without the optimizer.
- The compile phase of the warm load took about 3 minutes on both the
  plain and the optimized module; Sprint 11's record has "about 8
  minutes" for the dispatch-loop build. A timed rebuild of the Sprint
  11 tree on the same machine would make that number a measurement.
- Wasmtime's first compile of the optimized module (24 s, cached
  after): the cost of a smaller module is paid once per module change
  and matters for the browser host, which has no cache across origins.
