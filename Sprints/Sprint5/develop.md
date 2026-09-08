# Sprint 5 — development log

Branch `sprint5`, merged into `wasm-dev` when `uat.sh` is green. The
sprint covers plan Sprint 4 ("genesis, fasls and the core module",
`doc/wasm-port/04-sprints.md`): the cross-compiler's output becomes a cold
core plus one Wasm module holding every function of the core, with table
indices where the other targets have entry addresses (design 2.2).

## 1. Where the Wasm code goes (fasls)

A code component's instruction bytes are still assembled and dumped as
before (the flat segment with simple-fun headers, which genesis, the GC
and the debugger understand), but no Wasm engine ever executes them. The
executable form is the set of functions the function assembler lowers
from that segment (Sprint 4). It now travels with the component:

- `codegen.lisp`'s `assembly` struct has a `wasm-code` slot (`#+wasm`);
  `generate-code` stores what `wasm-note-component` returns.
- `dump-code-object` writes it right after the code bytes with a new
  fop, `fop-wasm-code` (opcode 26, `#+wasm`): one operand, the blob
  length; the bytes follow in the stream; the code object stays on the
  fasl stack. `dump-assembler-routines` does the same after
  `fop-assembler-code` (the routine blob comes from
  `wasm-note-assembly-routines`, which now always lowers the routine
  file).
- The target loader's `fop-wasm-code` reads the bytes and calls
  `sb-vm::wasm-install-code`, a stub until the host's instantiate import
  exists (Sprint 6).

The blob format is documented in `func-asm.lisp` ("Code blobs"): per
function its name, local declarations, body and a **patch table**; then
the map from simple-fun index to function. A patch is a five-byte LEB128
immediate the loader rewrites when the function is placed in a module
other than the one it was lowered for:

| kind | immediate | operand |
|---|---|---|
| `:function` | `call`/`return_call` target within the component | function index in the blob |
| `:assembly-routine` | `call`/`return_call` of a routine | routine name |
| `:type` | `call_indirect` type index | `(params results)` |
| `:assembly-routine-entry` | `i32.const` table index of a routine (fdefn trampolines) | routine name |
| `:foreign` | `i32.const` table index of a foreign function | symbol name |
| `:foreign-dataref` | `i32.const` address of a linkage cell | symbol name |
| `:coverage` | `i32.const` coverage byte offset | index |
| `:layout-id` | `i32.const` layout id (structure type tests) | classoid name, `PACKAGE::NAME` |

The lowering itself now emits every intra-component function reference
as a fixed five-byte immediate (`emit-function-ref`) and records the
patch, alongside the fixups the assembler noted; the bodies remain valid
for the differential rig's modules without any patching, since their
values are computed for that layout.

Lowering every component of the tree (which the rig-only hook never did)
found two gaps in the Sprint 4 function model, fixed in `func-asm.lisp`:

- **Entering a function at an arm other than its start.** IR2 emits
  conditional branches and local calls into blocks of another
  environment that are not that environment's first block, and an
  external entry point's block is not always emitted first. Arms are now
  assigned for all functions before any body is emitted (`assign-arms`,
  splitting at every branch target of the whole component plus the
  function's start), and a cross-function reference (`emit-cross-ref`,
  used for `:jump`, `:jump-if`, `:call-label`, `:tail-call-label` and
  chunk fall-through) stores the target arm + 1 in the module's
  **entry-arm global** (`+global-entry-arm+`, a mutable i32 every Lisp
  module defines) before the `call`/`return_call`. A function entered
  that way (`entry-arm-p`) begins with a prologue that moves the global
  into `$pc` (or its own start arm when the global is 0) and clears it;
  other functions pay nothing. Bodies are lowered again when a later
  caller marks them.
- **Simple-fun headers.** The XEP prologue now emits the aligned
  simple-fun header word and self slot (`simple-fun-header-word`, as on
  riscv), which genesis and the GC require in the flat code; the
  function's Wasm code starts after the header, and the header and
  alignment padding are never copied into a body.

## 2. Genesis and the core module

`fop-wasm-code` in genesis reads the blob into a host vector and keeps
`(code-object . blob)`; nothing lands in the cold heap. After cold load
(`build-wasm-core-module`, before the foreign symbol vector is written):

1. Parse every blob; number the functions: the assembler routines
   (first blob, first file loaded) then the components in load order,
   right after the module's four runtime imports.
2. Patch each body: function refs to module indices, routine calls to
   the routine's module index, types to the core module's type indices,
   routine entries and foreign functions to table indices, data refs to
   linkage cell addresses.
3. `wasm-add-function` for each; one active element segment at
   `i32.const +core-table-base+`; a custom section `sbcl.core.table`
   with the base and count so that the runtime sizes the table before
   instantiating (an element segment cannot grow the table, S0.1).
4. Simple-fun self slots: the table index of the entry's function.
   fdefn raw-address words: the function's table index, `closure-tramp`
   for a closure or funcallable instance, `undefined-tramp` when unbound
   (the same values `set-fdefn-fun`/`fdefn-makunbound` compute at run
   time, Sprint 4).
5. Write `<core>-core.wasm` and `<core>-core.wasm.symbols` (index, kind,
   name of every required foreign symbol, the runtime's linkage table).

`apply-fixups` no longer patches the code object on wasm: it only notes
foreign symbols (`:foreign`, `:foreign-dataref`) and accepts the four
module-level flavors. `fixup-code-object` stays unimplemented.

Table layout (`parms.lisp`): the runtime's own function pointers from 1,
foreign functions from `+foreign-table-base+` (1024) in linkage index
order, the core from `+core-table-base+` (4096), run-time modules above.

## 3. Loaders

`wasm/crates/sbcl-wasm-test/src/bin/load-core.rs` (Wasmtime) and
`tests/wasm/load-core.mjs` (V8 through Node, `--experimental-wasm-exnref`)
compile and instantiate the core module against a stub environment
(memory, a table sized past the core's range, the two globals, the
unwind tag, four runtime entry points) and check that the element
segment filled the range; both print size and compile/instantiate times.

## 4. Scripts

`pass1.sh`, `pass2.sh` (the stock `crossbuild-runner/pass-2.lisp`),
`genesis-only.sh` (genesis alone on the pass-2 fasls, with headers into
`obj/xbuild/wasm/genesis-headers` for the pass-1 comparison), `uat.sh`.
