# Sprint 7 — verification and further study

## 1. Exit criterion (plan Sprint 6, "cold init")

| Criterion | Result |
|---|---|
| `!cold-init` runs to the REPL | yes: the cold top-level forms, the cold-init `compile` calls (loaded as run-time modules), `toplevel-init`, the command line, the REPL over standard input (`test.md`) |
| `sbcl-wasm src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --eval '(print (+ 1 2))'` prints 3 | yes (`cold-init.txt`; 2.5 s from Wasmtime's module cache, about 30 s when the core module has to be compiled) |
| errors reach the condition system | yes: `(car 3)` at run time signals a `type-error` that `handler-case` catches; the debugger prints a backtrace under `--non-interactive` |

The plan budgeted two sprints for this; it took one, on top of the
Sprint 6 fixes.

## 2. What running cold-init taught (details in `develop.md`)

Thirteen defects, all of a kind the level-1 differential suite could not
show (its cases are single components without the calling convention's
long-range invariants, without foreign calls, and without a runtime):

- **Register and frame invariants across calls** (1, 2, 3): the
  `return` VOP's temporaries, CODE saved around local calls, a safe
  point for `&more` entries. Each was found with the entry trace
  (section 1 of `develop.md`), which is now the standard tool: run with
  `SBCL_WASM_TRACE_ENTRIES=1`, decode with `wasm-coreindex.py --annotate`.
- **Genesis versus the target** (4, 5, 10): the undefined-function
  trampoline referenced by address, the groveled constants of a
  stand-in target, a block-compiled function with no global definition.
- **The C side** (6, 7, 9, 11, 12): foreign call signatures must match
  the C prototype exactly; the runtime must not rely on globals only
  signal-based targets maintain (`current_control_stack_pointer`); the
  error entry is `funcall2` of `internal-error` with a synthesized
  context.
- **Run-time code loading** (section 3): every `compile` makes a module
  of its own; the shared table grows by `*wasm-table-next*`.

## 3. Open items

1. **The C shadow stack leaks on a non-local exit through C frames.**
   An error unwinds from `internal-error` (called from C) to the
   handler's `try_table` with a Wasm exception; the C frames of
   `wasm_internal_error`, `funcall2` and `call_into_lisp` are abandoned
   without their epilogues, so the runtime's `__stack_pointer` global
   stays lowered by their size (a few hundred bytes) for every error
   that unwinds through C. The 8 MB C stack (`Config.wasm-wasi`) holds
   thousands of such errors; the test suite will exceed that. Design
   for Sprint 8: the runtime exports `c_stack_save`/`c_stack_restore`
   (inline `global.get`/`global.set __stack_pointer`), the module
   imports them after `pending_interrupt`, `save-dynamic-state` gets a
   fourth result holding the C stack pointer and `restore-dynamic-state`
   restores it (the dynamic-state TN count follows the template's
   result count in `ir2tran`), the host and the rig's `minirt.c`
   provide the two functions.
2. **Errors are not continuable.** `emit-error-break` follows the
   `internal_error` call with `unreachable`, so `cerror`-style traps and
   the `use-value` restart of type errors (which return from the
   handler into the erring code with a register changed) end in the
   runtime's "handler returned" report. The error code paths would
   need a continuation label to jump back to, and the runtime would
   copy the context's registers back before returning.
3. **No program counter in the context.** The context's "pc" is the
   start of the erring code object's instructions, so the debugger
   attributes the frame to the component's first debug function and
   `error-context` (the "in function X, the value of Y" part of type
   error messages) is not available. The error break could pass the
   elsewhere label's position (a per-component offset) as a fourth
   argument, which is what the machine-code targets' PC gives.
4. **The GC does not run yet.** Cold init to the REPL and allocating
   200,000 small vectors fit in the dynamic space without a
   collection; an explicit `(gc)` stops in the collector:
   `unboxed object in scavenge_control_stack: 0x300e001c->f2` (word 7
   of the first frame, `call_into_lisp`'s). The common code scans the
   control stack precisely on this kind of target, and the frames here
   hold raw words (the register area is conservative already, Sprint
   1). Either the stack is scanned conservatively (as on x86) or the
   frames keep only boxed words. This is the first item of the plan's
   next sprint (garbage collector and warm load); the control stack
   scan now at least reads CSP from the register area (defect 11).
4a. **Backtraces stop at the interrupted frame.** The erring frame is
   found through the interrupt context (`(CAR 3) [external]`), but the
   frames below it print as `("foreign function: #x0")`: the frame
   walk (`compute-calling-frame`) needs a return address in each
   frame's `ra-save` slot to find the caller's code, and the calling
   convention here saves none (there is no program counter; the
   callee returns by a Wasm `return`). The debugger port must derive
   the caller's code object from the frame's `code-save` slot (saved
   since this sprint, defect 2) and its position from a per-call-site
   number stored by the call; the plan's debugger sprint.
4b. **Warm-load functions are unbound**, as in any cold core:
   `name-char` (`target-unicode.lisp`, a warm source), `describe`,
   `inspect` and the rest of `src/cold/warm.lisp`; the next sprint's
   warm load defines them.
4c. **The debugger and piped input.** Under a pipe the debugger's
   `clear-input` discards the rest of standard input on entry and
   returns to the REPL, so a piped session ends after the first error;
   the host SBCL behaves the same way (checked). With `--eval` the
   debugger reads its commands from standard input as usual.
5. **Interrupts are not delivered.** The host's Ctrl-C sets the
   interrupt-pending word; `pending_interrupt` prints a message and
   resets it. Delivering `sigint` into Lisp (`interrupt-thread`-style,
   from the safe point) and timers are for the sprint that does
   `sb-unix::*interrupt*`/`with-timeout`.
6. **Undefined C functions trap with a type mismatch, not a name.** The
   generated linkage table declares undefined functions `void f(void)`;
   a Lisp call of such a symbol fails the `call_indirect` type check
   before reaching the host's named trap. The linkage generator could
   declare them with the Lisp side's expected type, or the runtime
   could route every undefined symbol to a reporting function of the
   right shape (`tools-for-build/wasm-linkage-table.sh`).
7. **299 fdefns are unbound in the cold core** (from `wasm.map`); the
   ones cold-init calls have been dealt with (10); the rest are the
   usual not-yet-loaded warm functions plus block-internal names.
8. **`--fast` skips pass-2 whenever the core exists**, including after
   a target Lisp change; the manual now says to remove
   `obj/xbuild/wasm.core` first. A dependency check (newest source under
   `src/` versus the core) would remove the pitfall.

## 4. Further study

- The core module's compile time (26 s for 43,404 functions, 41 MB)
  dominates a cold start; Wasmtime's cache brings it to 2.5 s. For
  browsers (V8 streaming compilation, no persistent cache) the module
  should be split or lazily compiled; the plan's Phase 4 item.
- Every `compile` at run time instantiates a module through the host
  (about 3 ms each here). The warm load (next sprint) will make
  thousands of them; batching the components of one `load` into one
  module is the obvious optimization once that is measured.
- The level-1 rig should get cases for the invariants found here:
  multi-value returns into full-call frames, local calls whose callees
  tail-call, `&more` entries, foreign calls of `void` and pointer-
  returning functions. `tests/wasm/diff/cases.lisp` has
  `mv-entry-values-3` for the first.
