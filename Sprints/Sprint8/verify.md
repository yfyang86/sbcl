# Sprint 8 — verification and further study

## 1. Exit criteria (plan Sprint 7, "garbage collector and warm load")

| Criterion | Result |
|---|---|
| `gencgc` with the register area as a root set; `(gc :full t)`; the automatic trigger; allocation stress | met: `test.md`, group "the garbage collector" (heap verifier clean before and after each collection; 6 million vectors through the trigger with the live data intact; hash tables, weak pointers, `defun`, `compile` and errors after collections) |
| `save-lisp-and-die` through WASI | met: `tools-for-build/wasm-warm.sh` saves `output/sbcl.core` (66 MB, 7,125 run-time modules kept in `*wasm-loaded-modules*`) beside `output/sbcl-core.wasm` |
| the warm load: `output/sbcl.core` is produced | met: the 68 warm files (`src/cold/warm.lisp`: PCL, the external formats, `room`, `save`, ...) are compiled by the cold core and loaded by a fresh one |
| the saved core restarts and reaches the REPL | met: `--eval` and the stdin REPL work in the saved core; `defclass`, `make-instance`, `compile`, hash tables, `format`, the reader |
| `tests/gc-smoketest.pure.lisp` and `tests/coreparse.pure.lisp` pass | (from `test.md`) |

## 2. What the collector and the warm load taught (details in `develop.md`)

Eighteen defects, none in `gencgc`'s algorithm and none in the compiler
proper: every one was a contract between the port and code that assumed
a machine-code target.

- Nine were the collector's contracts with compiled code: precise stack
  words, the register area as a root, the trigger's path to a safe
  point, the store barrier and its element cards, the code "written"
  flag, the registers across a nested `call_into_lisp`, and two C type
  mismatches that only Wasm's typed `call_indirect` rejects.
- Six were the warm load's: patches resolved with the wrong object
  (`:layout-id`), a funcallable instance entered with itself in LEXENV,
  no guard for an undefined alien function, a pending collection under
  `*gc-inhibit*` never taken, a trigger never armed in a cold image, and
  a check in `room.lisp` that assumes stack allocation.
- Three were the saved core's: the runtime entering a closure with the
  closure in CODE, and the run-time foreign-symbol lookup returning a
  cell's address where the compiled code loads the cell.

The pattern: whatever is a *trampoline*, an *address* or *conservative*
on the machine-code targets (linkage cells, funcallable-instance and
closure entry, the C stack, `dynamic-extent`) has to be spelled out on
this target, and the places that spell it out (`emit-function-object-entry`,
`call_into_lisp`, the `foreign-symbol-*` VOPs, `foreign-symbol-address`)
must agree with each other. The tools that found the defects fastest
were the heap verifier (`SBCL_WASM_VERIFY_GC=1`), the entry trace
(`SBCL_WASM_TRACE_ENTRIES=1`), the host's register dump at a trap read
against a disassembly (`tools-for-build/wasm-func.py`, `--module` for a
dumped run-time module), and the index checker
(`SBCL_WASM_CHECK_FDEFNS`); all are in `WASM-Manual.md`.

## 3. Open items

1. **A trap seen once at the end of a warm compile** (`develop.md`,
   item 17): a frame near the bottom of the control stack read as
   zeros after the `--eval` had completed; four later runs of the same
   and neighbouring configurations completed. `SBCL_WASM_CHECK_STACK=1`
   is in place to catch the moment if it recurs. Until it is explained,
   the warm build is a step to rerun on failure, not to trust blindly.
2. **The C shadow stack leaks on a non-local exit through C frames**
   (carried from Sprint 7): the unwind from `internal-error` abandons
   the C frames of `wasm_internal_error`, `funcall2` and
   `call_into_lisp` without their epilogues (the trap register dumps
   show NSP around 1 MB after a warm compile, 7 MB into the 8 MB stack).
   Design: the runtime exports `c_stack_save`/`c_stack_restore`,
   `save-dynamic-state` gets a fourth result, `restore-dynamic-state`
   restores it, the host and the mini-runtime provide the two functions.
3. **The 512 MiB default heap is tight for the compiler.** The
   compiler's transient garbage is promoted before it dies and the older
   generations are collected only once their average age exceeds 0.75,
   so the warm compile retains about 350 MB at its peak with the default
   nursery (5 % of the heap). `wasm-warm.sh` runs with 1.5 GiB
   (`SBCL_WASM_WARM_HEAP`); a saved core's users get the 512 MiB
   default. Options: a larger default, or a generation policy that
   collects gen 1–3 when the heap is more than half full.
4. **A safe point only at function entry.** A loop that allocates
   without calling anything (inline `allocate-vector` in a `loop`)
   never polls: the trigger sets `*gc-pending*` and the loop fills the
   heap. The heap-exhausted error is then signalled correctly, but a
   poll on backward edges (as the machine-code targets get from the
   allocation trap) would collect instead.
5. **`dynamic-extent` is not honoured** (Sprint 4 carry-over): the
   `key-info` candidates of `make-key-info` are heap garbage
   (`room.lisp`'s check is `#-wasm`), and every `dx-let` conses.
6. **An undefined alien function called with a signature other than
   `void ()`** traps in the host's `call_indirect` type check before
   reaching `undefined_alien_function`, so the error is a trap rather
   than an `undefined-alien-error`. A per-signature guard table, or a
   host trap handler that maps the trap to the Lisp error, would fix it.
7. **Saved cores instantiate every run-time module separately**:
   7,125 modules at startup (3.2 s to the REPL against 1.5 s for the
   cold core, from Wasmtime's cache). Merging them into one module at
   save time (the table ranges are contiguous) would cut the startup
   and the core's size, and `*wasm-loaded-modules*` (27 MB of module
   bytes) is saved in the core.
8. **`gc_and_save` prints `munmap: Invalid argument` twice** (WASI has
   no `munmap`; `wasi-mman.c` returns an error the callers print) and
   the finalizer thread, `sysconf`, `waitpid`, `environ` and the other
   process functions are undefined aliens.
9. **Barrier cost.** `emit-gengc-barrier` is three loads, a shift, an
   and, an add and a byte store per marked store; a per-block "card
   already marked" cache, as x86-64's `2block-gc-barriers` does for
   registers, would remove more.
10. **Continuable errors, backtraces below the interrupted frame,
    interrupt delivery, finalizers** (Sprint 7 items) are unchanged;
    `run-pending-finalizers` after a full GC ran nothing in a probe.

## 4. Further study

- The one-off trap (item 1): if it recurs with the stack watcher on,
  the report names the phase (allocation, safe point, instantiation,
  runtime call, internal error) and the words; the candidates are a
  frame reused below CSP after a non-local exit that set CSP too low,
  and a C-side write with a stale control-stack pointer.
- Generation policy for a small heap (item 3): measure the retained
  heap across the warm compile with `bytes_consed_between_gcs` at 2 %
  and 10 %, and with `number_of_gcs_before_promotion` raised, before
  changing the default.
- Module merging (item 7): a saved core needs one module per table
  range only because each was compiled separately; concatenating the
  function bodies with a renumbered element segment is a pure function
  of the saved bytes.
