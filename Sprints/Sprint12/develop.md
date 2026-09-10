# Sprint 12 — development record (the stackifier)

Plan: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 11: stackifier"
(the directory numbering is one ahead of the plan). Design:
`doc/wasm-port/02-design.md`, 2.5, encoding 2.

## 1. The stackifier (`src/compiler/wasm/stackify.lisp`)

The function assembler of Sprint 3 (`func-asm.lisp`) splits a Wasm
function's bytes into *arms* (the ranges starting at every branch
target) and lowers them under a dispatch loop: `loop; block×n;
br_table $pc; end … end` with every branch a `local.set $pc; br $L`.
This sprint adds the structured encoding in front of it:

- **The graph.** `build-cfg` makes one node per arm plus a virtual entry
  node: a `:branch` edge for every `jump`, `jump-if` and `jump-table`
  note whose target is an arm of the same function, a `:fall` edge to
  the next arm unless the arm ended (an unconditional jump, a jump
  table, a tail local call or a terminator, section 2), and `:entry`
  edges from the virtual node to the start arm and to every other
  entry (the non-local entries of `catch`/`unwind-protect`, and the
  arms that another function of the component enters through a local
  call or a cross-function jump, `component-entry-arms`).
- **Analysis.** `cfg-analyze`: a depth-first walk from the entry for
  the reverse postorder, Cooper-Harvey-Kennedy dominators, and the
  reducibility test (every retreating edge's target dominates its
  source); the targets of those edges are the loop headers. An
  irreducible graph makes the function fall back to the dispatch loop
  (`lower-function-body` tries the stackifier first), and the fallback
  is printed as `; stackify: NAME: irreducible control flow, dispatch
  loop`, which the build logs count.
- **Emission** (`emit-tree`, the shape of Ramsey's "Beyond Relooper"
  and LLVM's CFGStackify): a node's dominator-tree children that
  branch targets need each get a `block` ending where the child
  starts, a loop header gets a `loop` around its subtree, the
  fall-through child (sole predecessor, not also a branch target of the
  node) is placed right after the node, and a branch is a `br`,
  `br_if` or `br_table` to the construct whose end (a block) or start
  (a loop) is the arm. The `*open*` stack of `func-asm.lisp` holds the
  constructs (`(:block . arm)`, `(:loop . arm)`) so that `depth-to`
  computes the label depths, and the cross-function branches
  (`return_call` to the function at the target, with the entry arm in
  the global) are unchanged.
- **Entries.** With several entries the body starts with a `br_table`
  on `$pc` over the arm indices: a function entered at a non-start
  arm keeps its `$pc` prologue (the entry-arm global), and the
  exception handler of a function with non-local entries sets `$pc`
  and branches to the outer `loop $L` as before, so the arm indices
  keep their meaning for the `catch` blocks (`:label-index`).
- **Safe points.** A branch to an open `loop` whose note is a block
  branch (the `:poll` data or a block label, Sprint 11) gets the
  back-edge poll first; a `br_if` that needs the poll becomes `if;
  poll; br; end`.

Levels 0 and 1 passed after one fix: a conditional skip to the very
next arm made that arm a fall-through child while a `br_if` needed a
block for it (`ft-child` requires that the node has no `:branch` edge
to it).

## 2. The false edges: 9,164 fallbacks, then 34

The first full compile fell back for 9,164 functions, nearly all of
them the body function of an ordinary defun. The probes
(`tests/wasm/diff/run-diff.lisp` in the after-xc core, the fallback
hook `sb-vm::*wasm-stackify-fallback-hook*`, the target disassembler's
decoder on the arm bytes) showed two shapes:

1. An arm ending in `i32.const 0; return` with a `:fall` edge to the
   next arm, which jumped back to it: the "loop" was the return path.
2. A block the compiler knows never falls through — a call to a
   function whose type says it does not return (`error`) — followed in
   the layout by a block that branches back before it: the call's
   return-point handling fell into that block and made a cycle with
   two entries (from the `if` before the call and from the call's
   continuation), which is irreducible by the book.

Both are the same thing: the graph had fall-through edges the code
never takes. Two changes remove them, and the assembler rather than a
decoder tells the stackifier where a block ends:

- `insts.lisp` keeps the nesting depth of the `block`, `loop`, `if`
  and `try_table` constructs open at the emission point (a VOP's
  constructs are balanced, so the depth is zero between VOPs, and
  `func-begin` resets it) and records a `:terminator` control note
  after `return`, `return_call`, `return_call_indirect`,
  `unreachable`, `throw` and `throw_ref` emitted at depth zero. The
  note is one placeholder byte like the others; the dispatch loop
  ignores it, `build-cfg` ends the arm at it, and the code after it in
  the arm (a note there lowers to `unreachable`) is dead.
- `generate-code` (`codegen.lisp`) ends every block whose only
  successor is the component's tail — a call the compiler knows does
  not return, or a return — with `unreachable`
  (`sb-wasm-asm::emit-block-terminator`), so that the call's
  return-point handling does not fall into whatever follows. On the
  native backends nothing follows such a block either; the byte is the
  price of saying so.

With both, the four sample files (`early-constantp`, `seq`,
`hash-table`, `list`: 3,057 functions) stackify completely, pass-2
reports 34 fallbacks over the whole tree and the warm load 61 (section
3).

## 3. The fallbacks that remain

Pass-2 (`obj/wasm-build/pass-2.log`, 34): the external format
`enc-basic` (9), `src/compiler/debug` (3), `fd-stream` (3), `ir1opt`
(2), and one each in `srctran`, `seqtran`, `life`, `knownfun`,
`ir1util`, `envanal`, `array-tran`, `toplevel`, `target-format`,
`reader`, `print`, `macros`, `irrat`, `filesys`, `fdefinition`; the
assembly routine `unwind` and two top-level forms. The warm load
(`warm-compile.log`, 61): 60 `lambda1` and one `lambda6`, mostly in
`src/pcl/boot.lisp` and the other external-format encodings
(`enc-*.lisp`). (A file's line in the build log follows its messages;
the first attribution read it the other way.)

The probe on `src/compiler/debug.lisp` and `enc-basic.lisp` shows what
they are: loops entered at an arm other than the one their back edge
targets. `PRINT-ALL-BLOCKS` (a `do-blocks` loop with a `handler-case`
in its body) enters the loop's body directly from the prologue while
the back edge returns to the test; the external formats' decoders and
the `fd-stream-read-sequence/utf-8-*` functions are `tagbody` loops
whose several `go` targets are entered from outside the loop, and
`check-tn-conflicts` and `pre-pack-tn-stats` are nests of `do-` loops
with `return-from` out of the inner ones. All are irreducible by the
definition (a loop with two entries), so the dispatch loop lowers them,
whole functions at a time; node splitting (duplicating the secondary
entry's arm) or a dispatch limited to the loop's entries would keep the
structured form for the rest of the function. About one function in
300 in pass-2; with the warm load's compile time the measure, not
worth more this sprint.

## 4. `wasm-opt` on the cold core module

binaryen 123's `wasm-opt` (`tools-for-build/wasm-env.sh`:
`BINARYEN_BIN_PATH`, pinned like the other tools; the `toolchain` step
downloads it when missing, and reports it optional) runs on
`obj/xbuild/wasm-core.wasm` in the new `opt` step of `build-wasm.sh`,
between `lisp` and `warm` (the saved cores carry a copy of the module
they ran with, `wasm_save_core_module`). Flags: the features the
backend and the runtime use (exception handling, tail calls, bulk
memory, non-trapping conversions, sign extension, mutable globals,
multi-value, reference types), `-O2`, and `-g` to keep the name
section that `disassemble` reads. The original stays as
`wasm-core.wasm.orig` (the step is idempotent and pass-2 removes both).

Findings on the way:

- Sprint 11's dispatch-loop module (42.6 MB): `-O1` 20 s, `-O2` 28 s,
  both to 39.9 MB; the stackified module (38.4 MB): `-O2 -g` 26 s to
  33.8 MB (12% smaller).
- `wasm-opt` merges identical function bodies
  (`duplicate-function-elimination`: 43,542 functions became 40,789)
  and drops an unused import, so the function indices change. The
  table is unaffected (the element segment is explicit), but the
  target disassembler assumed table slot `i` held function
  `base + i`; it now reads the element segment
  (`parse-wasm-module`, section 9) and maps a slot to its function.
- Wasmtime compiles a changed module on first use (24 s for the
  optimized module against a cached one's 1 s), the same as for any
  fresh module; the cache makes the later starts equal.

## 5. The build

Pass-1 (30 s: the host fasls of the unchanged files are reused), pass-2
and genesis (5 min), the runtime (7 s), the warm load: 3 min 9 s for
the compile phase and 40 s for the load and save — the warm compile
took about 8 minutes on the dispatch-loop build (Sprint 11's record),
the first measure of the stackifier's effect: the target compiling
itself runs about 2.5× faster. The products: `obj/xbuild/wasm.core`,
`obj/xbuild/wasm-core.wasm` (38.4 MB before `opt`), `output/sbcl.core`
(77.4 MB) with `output/sbcl-core.wasm`.

One thing not to do again: the after-xc core build (the level-1 tests)
and pass-2 both write `obj/xbuild/wasm/from-xc/`; run concurrently,
the first died on a fasl the second had just written.

## 6. cl-bench

`tests/wasm/bench/cl-bench-driver.lisp` compiles cl-bench's files with
the running Lisp (stand-ins for the two things it takes from ASDF and
trivial-garbage) and runs each benchmark a scaled number of times,
printing `RESULT name runs seconds`; `cl-bench-compare.sh` runs it
under two cores and prints the ratios and their geometric mean. The
measurements: `test.md`, section 3, and
`doc/wasm-port/baselines/sprint-12-cl-bench.md`.
