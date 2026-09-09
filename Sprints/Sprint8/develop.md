# Sprint 8 — development notes

Plan: `doc/wasm-port/04-sprints.md`, "Sprint 7: garbage collector and
warm load". Method as in Sprint 7: run, decode where it stops, fix,
rebuild (`./build-wasm.sh lisp runtime` after a compiler change, `--fast
runtime` after a runtime change), run again.

## 1. The garbage collector

Sprint 7 left `(gc)` stopping in the collector:
`unboxed object in scavenge_control_stack: 0x300e001c->f2`. Three things
were missing for `gencgc` on this target; none needed a change to the
collector's algorithm.

1. **The control stack is scanned precisely, and the NLX blocks held a
   raw word.** Genesis writes `GENCGC_IS_PRECISE 1` for every
   generational target whose C stack is not the control stack, so
   `scavenge_control_stack` walks every word between the stack base
   and CSP and stops at a word that is neither a pointer, an immediate
   nor a header. The word at fault was the `entry-pc` slot of an
   unwind block: `make-unwind-block`/`make-catch-block` stored the NLX
   entry's label index raw (`0xf2` = entry 242), and a raw index whose
   low bits are not zero is not a Lisp object. The slot now holds the
   index as a fixnum (`store-entry-index`, `nlx.lisp`) and the unwind
   landing code (`emit-nlx-handler`, `func-asm.lisp`) shifts it back.
   Every other word on the stack was already a Lisp object: frame
   pointers, NFP/NSP/BSP values and the saved CODE are aligned or
   tagged, `ra-save` is 0, dynamic-extent objects carry headers, and
   unboxed stack TNs live on the number stack.
2. **The register area was not a root.** S0.7 (Sprint 1) analysed this
   and wrote no code; the design's "scanned like an interrupt context"
   is now `pin_call_chain_and_boxed_registers` (`gencgc.c`, the precise
   targets' root pinning) pinning the referent of every boxed register
   of the register area (`BOXED_REGISTERS` from `vm.lisp`'s
   `boxed-regs`: A0–A3, L0–L5, OCFP, LEXENV, CODE), with the sticky
   card mark, exactly as it pins a context's boxed registers. Pinned
   objects do not move, so the register words stay valid without being
   rewritten. The contexts pushed by `wasm_internal_error` are handled
   by the same loop as on the other precise targets.
3. **The automatic trigger had no path to a GC.** `lisp_alloc` calls
   `trigger_gc` (`gengc.inc`) when the allocation crosses
   `auto_gc_trigger`: it sets `*gc-pending*` and
   `set_pseudo_atomic_interrupted`, which on the other targets makes the
   end of the current pseudo-atomic section trap into `maybe_gc`. The
   wasm `pseudo-atomic.h` had those macros as no-ops. They now set,
   test and clear a bit (4) of the register area's interrupt-pending
   word, the word every XEP polls; `pending_interrupt` sees the bit and
   calls `maybe_gc` when `*gc-inhibit*` is NIL (leaving the bit set
   otherwise, so that the end of the `without-gcing` runs it through
   `receive-pending-interrupt`, which is the same import). A safe point
   is the right place: the GC must not run inside the allocation call
   itself, where the new object is only in a C local, and at an XEP
   every live value is in the register area or on the control stack.
   The pending word is now a bit set: 1 the host's Ctrl-C (the host ORs
   it in), 2 the entry trace, 4 a pending GC.

With 1–3, `(gc)` reached the collector and stopped in
`scavenge_control_stack` with "indirect call type mismatch":

4. **The pointer scavenger table was declared with the wrong type.**
   `gc-tables.h` (written by `late-objdef.lisp`) declared
   `scav_ptr[4]` as returning `void` and cast the four `sword_t`-returning
   scavengers into it; on the machine targets a call through such a
   pointer is undefined behavior that happens to work, and Wasm's typed
   `call_indirect` rejects it. The table is now declared with the
   functions' type (`gc-common.c`'s forward declarations too), a change
   that is correct on every target.

After 4 the collector ran to completion, and the probes showed the real
problem: `(gc)` followed by `compile`, `defun`, `make-hash-table` or the
error handler itself ended in "object is of the wrong type" errors,
eleven deep. Every one of those modifies a core-resident object to point
at a fresh one (globaldb, the type caches, the alien type cache):

5. **The backend emitted no store barrier.** With `:soft-card-marks` the
   collector scans an old object for pointers into younger generations
   only if the card holding the object is marked, and marking is the
   compiled code's job at every store of a pointer into a heap object.
   No wasm VOP did it, so after a collection the old objects pointed at
   the old addresses of moved (or freed) young objects. `emit-gengc-barrier`
   (`macros.lisp`) marks the card: the byte at
   `gc_card_mark[(object >> gencgc-card-shift) & gc_card_table_mask]` is
   set to `card-marked` (0). The table's address and the mask are two
   words of the register area (offsets 460 and 464) that `call_into_lisp`
   writes from the C variables, so the barrier is three loads, a shift,
   an and and a byte store with no foreign reference (the first draft
   read the C variables through their linkage cells, which would have
   put foreign patches into every level-1 test module; the mini-runtime
   now provides a one-card table with mask 0 instead). Emitted by:
   `set-slot`, `cell-set` (so `set`, `%set-symbol-global-value`,
   `value-cell-set`), `compare-and-swap-slot`,
   `%compare-and-swap-symbol-value`, `set-fdefn-fun`, `code-header-set`,
   `define-full-setter` and `define-full-casser` when the value can be a
   descriptor (`%instance-set`, `data-vector-set/simple-vector`,
   `%weakvec-set`, `%instance-cas`, ...), and, because this target has no
   thread-local storage and a binding writes the symbol's value cell,
   `dynbind`, `unbind` and `unbind-to-here`. `set-slot` and the full
   setters declare `:gc-barrier` (as x86-64 and arm64 do), so the IR2
   optimizer decides per store whether a mark is needed (not for a
   fixnum or character value, a stack-allocated object, or an object
   allocated earlier in the same block, and it knows the allocator
   context of a `:allocator` store; calling `require-gengc-barrier-p`
   from the `set-slot` generator itself broke on the constructor of
   `make-weak-pointer`, whose node is the allocator call). `cell-set`
   asks `require-gengc-barrier-p` about its value; the compare-and-swap
   VOPs, `set-fdefn-fun`, `code-header-set` and the binding VOPs always
   mark.

   The first version of the barrier marked the card of the object's
   header for every store. That is right for instances, which the
   collector scans whole from the card of their header, but a vector
   (a hash table's key/value vector, globaldb's storage) spans many
   cards and the collector looks only at the words on the marked
   cards: a store into an element on a later card went unseen, and
   after the next collection the element pointed at a moved or freed
   object. The symptoms were the same as without a barrier, only
   rarer: `compile`, `defun` and the error handler failed after a GC
   while the probes on small tables passed. For an element of a vector
   (or of a code object's boxed section) the barrier now marks the
   card of the element itself (`define-full-setter`,
   `define-full-casser` and `code-header-set` pass a function that
   pushes the cell's address), as x86-64 and arm64 do.

The element-card version still failed in the same way, so the next step
was the collector's own verifier instead of more guessing:
`SBCL_WASM_VERIFY_GC=1` (wasm-arch.c) sets `verify_gens` and
`pre_verify_gen_0`, and `verify_heap` reports every pointer to a stale
object before and after each collection. Its first run named two things:

6. **The verifier and `scav_fdefn` read an fdefn's raw-addr as an
   address.** On this target the slot holds the callee's table index;
   `decode_fdefn_rawfun` returned it minus an offset, the verifier
   reported every fdefn as a "strange non-pointer" and the scavenger
   would have adjusted the index had it ever looked like a pointer into
   from-space. `decode_fdefn_rawfun` returns 0 on wasm (the callee is in
   the `fun` slot, scavenged like any pointer).
7. **`code-header-set` did not set the header's "written" flag.** The
   collector scans the boxed words of an old code object only when
   `OBJ_WRITTEN_FLAG` (`code.h`, bit 6 of the header's fourth byte) says
   they were written after the object was made; the card mark alone is
   not enough (`gencgc.c`, the `header_rememberedp` tests). Cold-init
   writes constants into 844 core code objects (the verifier's count:
   debug-info, fixup vectors, the assembler routines' table); after a
   collection every one of them pointed at a freed or forwarded object,
   and the compiler and the error handler are among their users. The
   VOP now sets the flag as the mips and riscv `code-header-set` do.
   With 6 fixed the verifier's post-GC report listed only code objects,
   which is what made 7 certain.

With 7 the verifier is clean before and after collections, and `defun`,
`compile`, `make-hash-table` and the error handler work after them
(`test.md`).

## 2. Foreign calls with 64-bit integers

`compile-file` stopped with "indirect call type mismatch" in
`sb-unix::get-timezone`: `get_timezone(time_t, ...)` has an i64 parameter
on wasi (`time_t` is 64 bits) and the call passed an i32. The alien
machinery of a 32-bit target has no 64-bit representation, so the port
does what the 32-bit arm backend does for `long long`: a transform on
`%alien-funcall` (`c-call.lisp`) splits a 64-bit integer argument into
its two 32-bit halves and a 64-bit result into two 32-bit values that it
recombines. The high half is typed `(signed 33)` or `(unsigned 33)`, a
width no C type has, which the wasm `:arg-tn`/`:result-tn` methods turn
into a TN of primitive type `wasm-i64-high`; `call-out` merges such a
pair into one i64 parameter (`i64.extend_i32_u`, shift, or) and splits
an i64 result across the two adjacent result registers (one `i64.store`
at NL0). The first draft used a new alien type class as the marker; the
cross-compiler could not load its definition, hence the width trick.

## 3. Saving a core with code compiled at run time

`save-lisp-and-die` writes the heap, but the functions of code compiled
at run time live in modules the host instantiated, which no core file
holds. The core keeps them: `wasm-install-code` pushes each module's
bytes and table base onto `*wasm-loaded-modules*`, a static symbol, and
`wasm_load_core_module` (wasm-arch.c) instantiates the saved modules
again, oldest first, at their recorded table ranges right after the core
module (in a cold core the symbol is unbound and nothing happens). The
saved core's initial function itself is run-time code (the `restart-lisp`
closure `save-lisp-and-die`, a warm file, makes), which is why the
runtime and not Lisp does this. The warm load makes thousands of small
modules; merging them into one at save time is the obvious next step
(`verify.md`).

## 4. The warm load

`tools-for-build/wasm-warm.sh` (`./build-wasm.sh warm`) is
`make-target-2.sh` under the host: the cold core compiles
`src/cold/warm.lisp` with its own compiler into `obj/from-self/`, a
fresh cold core loads the fasls through `make-target-2-load.lisp` and
saves `output/sbcl.core`, and the core module is copied beside it. The
warm sources reference foreign names the cold core does not, so the
linkage table (generated from the cold core's symbol list) is extended
after the first link with every name the Lisp sources mention that the
runtime defines or imports (`tools-for-build/wasm-linkage-extra.sh`,
`llvm-nm` over the runtime's objects) and the runtime is linked again.

The first warm compile (`room.lisp`) trapped inside `gethash` with CFP 0,
OCFP 0x100 and a hash value in NARGS: the registers a `call_into_lisp`
leaves behind.

8. **A collection at a safe point clobbered the interrupted function's
   registers.** `maybe_gc` calls `sub-gc` through `call_into_lisp`,
   which writes NARGS, CFP, OCFP, LEXENV, CODE and the argument
   registers of the same register area and restores only CSP; the
   interrupted XEP went on with `sub-gc`'s registers. (The allocation
   stress test had passed by luck: nothing it interrupted needed its
   registers afterwards.) `pending_interrupt` now copies the register
   area into an interrupt context around the collection, as
   `wasm_internal_error` does for errors: the collector pins what the
   context's boxed registers reference, so the copy stays valid, and
   it is written back when `maybe_gc` returns.
9. **The fasl loader applied fixup records.** `warm.lisp` loads each
   file right after compiling it, and `room.fasl` carried fixup records
   (the machine-code kinds `dump-fixups` writes for every target), which
   `load-code` handed to `apply-fasl-fixups` and thus to the
   `fixup-code-object` stub. On this target a code object's references
   are the patches of its Wasm blob, resolved by `fop-wasm-code` through
   `wasm-install-code`; the loader now skips the records, as
   `make-core-component` already did for in-memory compiles.
10. **`room.lisp`'s key-info check assumes stack allocation.** Loading
    `room.fasl` asserts that every `key-info` instance in the heap is in
    `*key-info-hashset*`. `make-key-info` builds its candidate in a
    `dx-let` and inserts a copy only when the set has no equal entry;
    the backend does not honour `dynamic-extent` yet, so the candidates
    are heap garbage that `list-allocated-objects` still walks (366
    before a collection, 10 pinned by stale register and stack slots
    after a full one). The check is `#-wasm` until stack allocation
    exists.
11. **`:layout-id` patches resolved the id of a symbol.**
    `wasm-layout-id-of` (the loader's counterpart of genesis'
    `cold-layout-id`) handed the classoid *name* to `ensure-layout-id`,
    which read the id words of a symbol; `defpackage.fasl` was the first
    fasl whose structure type check (`symtbl-magic`, from the
    `symtbl-%cells` slot type) is not one of the wired layouts. It now
    looks the layout up with `find-layout`, which also creates the
    forward-referenced layout the machine-code loaders create in
    `apply-fasl-fixups`.
