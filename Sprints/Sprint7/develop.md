# Sprint 7 — development notes

Plan: `doc/wasm-port/04-sprints.md`, "Sprint 6: cold init". The method is
the one Sprint 6 ended with: run the cold core, decode where it stops,
fix, rebuild (`./build-wasm.sh lisp runtime`, about twenty minutes when
the compiler changed, `--fast runtime` for runtime-only changes), run
again. Each defect below names the symptom, the cause and the fix.

## 1. The entry trace (a safe point in every XEP)

Reading Wasm by hand to find which callee corrupted a register does not
scale, and Wasmtime offers no wasm-to-wasm call hook. Every XEP now
tests the register area's interrupt-pending word (offset 456,
`+thread-interrupt-pending-offset+`) and calls the runtime's
`pending_interrupt` import when it is nonzero: `emit-safe-point` in
`src/compiler/wasm/call.lisp`, emitted by `xep-setup-sp` and, for entry
points with `&more` arguments (which get no `xep-setup-sp`), by
`copy-more-arg`. The word is 0 normally, 1 for an interrupt request
(the host's Ctrl-C; not yet delivered into Lisp) and 2 for the entry
trace: `SBCL_WASM_TRACE_ENTRIES=1` makes the runtime set it to 2 after
instantiating the core module, and `pending_interrupt` then prints each
entry's callee (the fdefn name for a named call, else the function's
table index) and NARGS, CFP, CSP, OCFP, A0, A1. Local functions have no
XEP and do not appear.

`tools-for-build/wasm-coreindex.py --annotate` decodes the table indices
in a trace or backtrace from the module's name section; `header:ADDR`
lists a component's boxed constants by name (fdefns, symbols, strings);
`tools-for-build/wasm-func.py` prints one function with offsets. The
host's trap report now also dumps the first words of the frames at OCFP
and CFP, and `SBCL_WASM_TRACE_ALLOC=1` prints the frame registers at
every allocation (the runtime wraps `alloc`/`alloc_list` for this).

## 2. Defects found and fixed

1. **`return` VOP clobbered OLD-FP.** The multiple-value `return` wrote
   the NARGS and OCFP registers without declaring them as temporaries,
   so the packer could keep `old-fp` in NARGS; storing the value count
   then made `CFP := old-fp` return to frame 0xc (fixnum 3, the count).
   Symptom: `%make-hash-table` faulting after `pick-table-methods`
   returned three values. Fix: the two registers are declared
   temporaries (as on the other backends), so `old-fp` is never packed
   there.
2. **CODE after a local call whose callee ends in a full tail call.** A
   local function (`buckets` in `package-registry-update`) tail-called
   `delete-duplicates`; the full callee returned straight to the local
   call site, where nothing restored CODE (only full-call sites did, as
   of Sprint 6). Every constant the caller loaded afterwards came from
   `delete-duplicates`'s code header: a `two-arg-and` call became a
   two-argument call of `sequence-bounding-indices-bad-error` (the same
   header word in the other component). Fix: `call-local` and
   `multiple-call-local` save and restore CODE in the caller's
   `code-save-offset` slot exactly as full calls do (`known-call-local`
   cannot end in a full tail call: its values are known).
3. **No safe point for `&more` entries** (a trace gap that hid
   `delete-duplicates` in the entry trace): `emit-safe-point` in
   `copy-more-arg`.
4. **Undefined fdefns called through an address, not a table index.**
   `finish-symbols` (generic genesis) stores `undefined-tramp`'s
   *address* in the raw-addr slot of every fdefn without a function,
   and it runs right after `build-wasm-core-module` had stored the
   trampoline's table index there. The first call of an undefined
   function (`sb-vm::fastrem-32`, see 5) then did `call_indirect` on
   the address 0x1100848 and trapped with "undefined element" instead
   of reaching the trampoline. Fix: that loop is `#-(or linkage-space
   wasm)`. (The core has 299 fdefns without functions at this point;
   all but one are filled in later by warm load, PCL and the like.)
5. **`sb-vm::fastrem-32` had no wasm implementation.** `symbol-table-hash`
   (package symbol tables) calls it; sparc defines it as a function,
   the other backends as a VOP. Wasm gets a VOP in `arith.lisp`:
   `i32.mul`, widen both factors to i64, `i64.mul`, shift right 32.
6. **The stand-in groveled constants were x86-64's.** `heap-allocated-p`
   (reached through `%proclaim` of a `freeze-type` declaration in a cold
   top-level form) reads the C variable `next_free_page` as
   `page-index-t`, which the stand-in
   `crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp`
   declared `(signed 64)`: eight bytes read where the runtime has four,
   a garbage bignum, and `sap+` signalling "not an (unsigned-byte 32)".
   The Sprint 6 deferral is therefore done now: `tools-for-build/grovel-headers.c`
   compiles for wasm32-wasi (`LISP_FEATURE_WASM` gates the headers WASI
   lacks and supplies placeholder values for the constants of those
   headers, which nothing on this target uses; WASI clock ids are
   pointers, so the target uses Linux's numbers and `sb_clock_gettime`
   in `wrap.c` maps them back), and `tools-for-build/wasm-grovel-headers.sh`
   runs it under the host to regenerate the file (`./build-wasm.sh
   grovel`; `all` runs it before `lisp`). Beyond the type widths, the
   real file differs from the stand-in in every errno number, the
   `O_*` flags, the poll flags and `sizeof-sigset_t`: the previous
   values were simply wrong for WASI.
7. **Foreign call types must match the C function exactly.** A
   `call_indirect` traps ("indirect call type mismatch") when the
   Lisp-declared signature differs from the callee's Wasm type, which
   native platforms never notice: `memmove` was declared `void` (it
   returns a pointer), reached from `%output-integer-in-base` through
   `ub8-bash-copy`. Fixed in the declaration (`#+wasm
   system-area-pointer`). `exit` and `_exit` are declared through
   `syscall` as returning `int` while C's are `void`: the linkage table
   (`wasm-linkage-table.sh`) maps those two names to int-returning
   wrappers in `wasm-arch.c`; `sigprocmask` (declared `void` in
   `target-signal-common.lisp`) is defined `void` on this target. An
   audit of the other 160-odd foreign functions the core names found no
   other `void` mismatch, and the regenerated groveled types (6) remove
   the 32/64-bit ones. Future declarations for this target should be
   checked the same way (`verify.md`).
8. **`write-funinstance-prologue` looked for a trampoline routine that
   does not exist here.** PCL's bootstrap (`!bootstrap-meta-braid` →
   `allocate-standard-funcallable-instance`) calls it; the generic
   `#-executable-funinstances` version stores the address of the
   `funcallable-instance-tramp` assembly routine in the instance, and
   the wasm assembly file has no such routine, so `get-asm-routine`
   returned NIL and `(setf sap-ref-word)` signalled "not an
   (unsigned-byte 32)". Funcallable instances need no trampoline on
   this target (callers and `call_into_lisp` go through the function
   slot), so `wasm-vm.lisp` defines the function as a no-op and the
   generic one is `#-(or executable-funinstances wasm)`.
9. **The target had `:os-provides-dlopen`.** `pass-1.lisp` adds it to
   every crossbuild, so `!foreign-cold-init` ran `dlopen-or-lose` and
   called `dlerror`, a function the runtime does not define. Such calls
   cannot even reach the host's named trap: the generated linkage table
   declares every function `void f(void)`, and for a symbol nobody
   defines that declaration decides the import's Wasm type, so Lisp's
   `() -> i32` call mismatches first. The design (2.9) has no dynamic
   loading on this target: the build passes `(not :os-provides-dlopen)`
   to pass-1 (`build-wasm.sh`, `Sprints/Sprint5/pass1.sh`), which makes
   `load-shared-object` an unsupported operator and removes the
   `dl*` calls. Calls to other undefined C functions will still trap
   with a type mismatch rather than a name; that is noted in `verify.md`.
   Dropping the feature also drops `unix-foreign-load.lisp`, the only
   definition of `find-dynamic-foreign-symbol-address`, which
   `foreign.lisp` calls to resolve names at run time; `wasm-vm.lisp`
   defines it over the runtime's `os_dlsym_default` (the generated
   linkage table: a function's table index or a data address).
10. **`iteration-step-values` had no global definition.** Cold-init's
    first `compile` (a perfect-hash function for a `member` transform,
    reached from `try-perfect-find/position-map`) ran the IR1 optimizer,
    whose `optimistic-step-p` calls `iteration-step-values`; that
    function sits inside the `ir1opt.lisp` block whose `start-block`
    entry list does not name it, while `optimistic-step-p` is defined
    after the `end-block`. Block-internal functions get neither an XEP
    nor a `fop-fset`, so the core's fdefn was unbound (the map showed it
    among the 299 unbound fdefns) and the call went to the undefined
    trampoline. Fix: the name is added to the block's entry list. This
    is a defect of the upstream snapshot rather than of the port; it
    surfaces here because cold-init calls the compiler this early.

## 3. Loading code at run time (the first `compile`)

With 10 fixed, cold-init's first `compile` produced a code object and
then called it: the simple-fun self slot held no table index, since
`wasm-install-code` was still the Sprint 5 stub. The design's 2.2 is now
implemented on the target (`src/code/wasm-vm.lisp`):

- `make-core-component` (`core.lisp`) skips the machine-code fixups on
  wasm (the references live in the Wasm blob, `asm-wasm-code`) and,
  after the generic self-slot assignment, calls
  `(wasm-install-code code-obj blob)`; the fasl loader's `fop-wasm-code`
  calls the same function.
- `wasm-install-code` parses the blob (`parse-wasm-code`), builds a
  module with `make-lisp-module`, imports every assembly routine the
  code calls directly from the shared table by index (import module
  `"table"`, name the decimal index; the host resolves those from the
  runtime's `__indirect_function_table`), resolves the patches as
  genesis does (`:function` within the module, `:assembly-routine-entry`
  to the routine's table index, `:foreign`/`:foreign-dataref` to the
  linkage cell after `ensure-alien-linkage-index`, `:type` to the
  module's type index, `:layout-id` through `ensure-layout-id`), takes
  the next free table range from `*wasm-table-next*`, adds the element
  segment and the `sbcl.core.table` section, and hands the bytes to the
  runtime's `wasm_instantiate_module`, which calls the host's
  `sbcl_host.instantiate` with the register area. The entries' self
  slots then get their table indices (same numbering as genesis).
- Genesis gives the target `*wasm-routine-table*` (routine name to
  table index) and `*wasm-table-next*` (`+core-table-base+` plus the
  core's function count).

The host keeps every instance alive for the life of the store and
grows the table as ranges are claimed.

The rebuild with the loader failed first: skipping the fixups on wasm
left `make-core-component`'s `real-code-obj`, `fixup-notes` and
`retained-fixups` unused, a full warning under the cross-compiler's
`FAILURE-P` policy; the wasm branch now references them.

## 4. To the REPL, and what it took

With the loader in place the cold core runs `!cold-init` to the end:
the cold top-level forms, the `compile` calls of the cold init
(perfect-hash functions and the like, each a small module of one or two
functions instantiated at run time), `toplevel-init`, the command line,
and `--eval '(print (+ 1 2))'` prints 3 and exits 0. A run takes about
30 s the first time (compiling the 43,404-function core module) and
about 2.5 s from Wasmtime's module cache afterwards. Two more defects
showed up at the REPL:

11. **`scrub-control-stack` zeroed the live registers.** The REPL's
    loop calls `scrub-control-stack` (C) before every read; the common
    `scrub_thread_control_stack` starts at
    `access_control_stack_pointer(th)`, which on a non-threaded target
    is the C global `current_control_stack_pointer`, which nothing on
    wasm ever sets. Scrubbing started at a wrong place and did not stop
    before it had zeroed the register area (the trap showed CFP, CODE and
    LEXENV all 0, then a `call_indirect` through table slot 0:
    "uninitialized element"). `thread.h` now defines
    `access_control_stack_pointer` and `access_control_frame_pointer`
    for wasm as the CSP and CFP words of the register area. The GC's
    conservative stack scan uses the same accessor, so this also gives
    the collector the true top of the control stack (it had not run
    yet at this point of cold init; see `verify.md`).
12. **Internal errors were fatal.** `wasm_internal_error` (the
    `internal_error` import) printed the registers and trapped. It is
    now the target's `interrupt_internal_error`: it copies the register
    area into an `os_context_t` (the context also carries the trap
    kind, error code and the SC+OFFSET words of the arguments, which is
    what `internal-error-args` in `wasm-vm.lisp` reads through
    `os_context_error_args_addr`; its "pc" is the start of the current
    code object's instructions so the debugger can find the component),
    binds `*free-interrupt-context-index*` and stores the context in the
    thread's context array (so `find-interrupted-frame`,
    `sub-access-debug-var-slot` and the register accessors see the
    erring frame), and calls `internal-error` through `funcall2`. The
    handler leaves by the condition system's non-local exit through the
    C frames (a Wasm exception passes C frames untouched); the dynamic
    binding is undone by the unwind. A return of the handler is fatal:
    errors are not continuable on this target (the code after the
    `internal_error` call is `unreachable`), see `verify.md`.
    `SBCL_WASM_TRACE_ERRORS=1` prints every internal error the runtime
    receives (kind, code, arguments, registers, the fdefn in LEXENV).
13. **`internal-error-args` returned no trap number.** The first error
    that entered Lisp (`(car 3)`, `object-not-list-error`) nested
    eleven errors deep: `internal-error` binds
    `*current-internal-trap-number*` to the third value of
    `internal-error-args` and later compares it with `cerror-trap`
    using `=`, and the wasm version returned only two values, so the
    comparison signalled `object-not-number-error` from inside the
    handler, again and again, until `*maximum-error-depth*`. The
    function now returns the trap kind as the third value.

After 13, `(handler-case (car (read-from-string "3")) (error (e) ...))`
prints the condition (`test.md`); the stdin REPL reads, compiles and
calls definitions (`(fib 20)` = 6765) and prints its prompt.
