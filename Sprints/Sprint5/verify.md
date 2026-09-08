# Sprint 5 — verification notes and further study

## What was verified

- `crossbuild-runner` pass-2 for the wasm target runs to the end: the
  tree cross-compiles with the real dumper (every component lowered to
  Wasm and carried in its fasl), and genesis cold-loads all 301 fasls
  (5,381 toplevel forms) into `obj/xbuild/wasm.core` (41 MiB) and emits
  `obj/xbuild/wasm-core.wasm`: 36 MiB, 43,487 functions from 20,052 code
  components plus the four assembler routines, installed in the funcref
  table at 4096..47582. `wasm-tools validate --features all` accepts it.
- The 168 foreign symbols the core needs are listed in
  `wasm-core.wasm.symbols` (index, kind, name), the runtime's linkage
  table in the making.
- Genesis run the way `make-host-1` runs it (headers only) and the way
  pass-2 runs it (with all the fasls) write identical header sets
  (31 files).
- The core module compiles and instantiates against a stub environment
  in Wasmtime 45 (Cranelift) and in V8 (Node 22, `--experimental-wasm-exnref`),
  and the element segment fills the whole table range.

| Engine | Compile | Instantiate |
|---|---|---|
| Wasmtime 45, Cranelift, this container | 20.7 s | 6 ms |
| V8 (Node 22.22), lazy compilation | 0.10 s | 9 ms |

  Against the S0.1 budget (Cranelift: 5.6 MB / 400,000 tiny functions in
  7.1 s), 36 MiB of real functions (about 880 bytes each, dispatch loops
  included) cost 21 s, which confirms the S0.1 conclusion: the standalone
  host must use precompiled modules (`wasmtime compile` /
  `Module::serialize`), and V8's lazy compilation makes the browser start
  cheap. Sizes will drop with the Phase 3 stackifier (structured control
  flow instead of dispatch loops) and `wasm-opt`.
- Level 0 and the Sprint 3-4 level-1 suite (162 cases, 442 argument
  sets) still pass with the reworked lowering (`test.md`).

## Findings

1. **The whole-tree cross-compile had never lowered anything.** Until this
   sprint `wasm-note-component` only lowered a component when the rig's
   hook was set, so after-xc's "zero unimplemented VOPs" said nothing
   about the function assembler on real code. Lowering every component
   for the fasl exposed:
   - conditional branches into another environment's block (`:jump-if`
     to a non-local label, first seen in `early-classoid`), and more
     generally entries into another function of the same component at a
     label that is not that function's first block. Both are now one
     mechanism: the caller stores the target arm (+1) in the module's
     entry-arm global and calls or tail-calls the function, whose
     prologue reads and clears it (`emit-cross-ref`, `assign-arms`; only
     functions actually entered that way pay for the prologue);
   - external entry points whose entry block is not the environment's
     first block: the function's start is its entry label, and arms are
     computed after all the component's branch targets are known.
2. **Simple-fun headers.** The XEP prologue emitted no header word and no
   alignment, which genesis rejected ("unaligned function entry"). The
   header (`simple-fun-header-word`, a back-patched word with the code
   offset, then the self slot) is now emitted as on riscv; the function
   assembler starts the XEP's code after it and never copies header or
   padding bytes into a body.
3. **Genesis details.** The cold `fop-assembler-code` returned the value
   of its last form (T) rather than the code object, so the following
   `fop-wasm-code` popped T; it now returns the code object. Descriptors
   read back from the fasl stack are fresh objects, so the assembler code
   is recognised by address, not `eq`. `:layout-id` fixups (structure
   type tests against a layout that has no small id yet) are a patch
   kind of their own, carrying the classoid name; genesis resolves them
   through `*cold-layouts*`.
4. **Nothing runs yet.** The exit criterion is "loads, not runs": the
   fdefn raw addresses, self slots and trampolines are written but the
   runtime that would call into the module is Sprint 6's. The
   differential rig remains the only execution check of the backend.

## Open items and further study

- The cold core's flat code bytes are dead weight in the heap (the Wasm
  bodies live in the module); they keep the code object layout the GC
  and `sb-di` expect. Dropping them (a code object without an unboxed
  area) is a later space optimisation.
- Coverage marks: `:code-coverage-index` fixups are dumped but refused
  by genesis; `mark-covered` needs the coverage byte address, which the
  loader can compute from the constant vector's position once code
  objects are relocatable at run time.
- `wasm-install-code` (loading fasls at run time) waits for the host's
  instantiate import (Sprint 6, runtime port).
