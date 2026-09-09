# Sprint 8 — verification and further study

## 1. Exit criteria (plan Sprint 7, "garbage collector and warm load")

| Criterion | Result |
|---|---|
| `gencgc` with the register area as a root set; `(gc :full t)`; allocation stress | (filled in from `test.md`) |
| `save-lisp-and-die` through WASI | |
| the warm load: `output/sbcl.core` is produced | |
| the saved core restarts and reaches the REPL | |
| `tests/gc-smoketest.pure.lisp` and `tests/coreparse.pure.lisp` pass | |

## 2. What the collector taught (details in `develop.md`, section 1)

Nine defects, none in the collector's algorithm: every one was a
contract between compiled code and `gencgc` that the port had not
honored (precise stack words, roots, the trigger's path to a safe point,
the store barrier and its element cards, the code "written" flag, the
registers across a nested `call_into_lisp`) or a C type mismatch that
only Wasm's typed `call_indirect` rejects (`scav_ptr`, and in Sprint 7
`memmove`). The heap verifier (`SBCL_WASM_VERIFY_GC=1`) found the last
three in one run each; it should be the first tool, not the last, on
any future GC symptom.

## 3. Open items

1. **The C shadow stack leaks on a non-local exit through C frames**
   (carried from Sprint 7): an error's unwind from `internal-error`
   abandons the C frames of `wasm_internal_error`, `funcall2` and
   `call_into_lisp` without their epilogues. Design: the runtime
   exports `c_stack_save`/`c_stack_restore`, `save-dynamic-state` gets a
   fourth result, `restore-dynamic-state` restores it, the host and the
   mini-runtime provide the two functions.
2. **Barrier cost.** `emit-gengc-barrier` is three loads, a shift, an
   and, an add and a byte store per marked store. The compiler's
   `:gc-barrier` analysis elides marks for fresh objects and non-pointer
   values; a per-block "card already marked" cache, as x86-64's
   `2block-gc-barriers` does for registers, would remove more.
3. **Saved cores instantiate every run-time module separately.**
   The warm load makes thousands of small modules, saved as
   `(table-base . bytes)` and instantiated one by one at startup.
   Merging them into one module at save time (renumbering nothing: the
   table ranges are contiguous) would cut startup and the core's size.
4. **Continuable errors, backtraces below the interrupted frame,
   interrupt delivery** (Sprint 7 items) are unchanged.
5. **Finalizers** registered with `sb-ext:finalize` did not run in the
   probe (`run-pending-finalizers` after a full GC printed nothing);
   the finalizer machinery expects a thread or the `post-gc` path to
   run them, which this target does not have yet.
