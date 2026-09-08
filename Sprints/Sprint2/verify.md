# Sprint 2 — verify and further study

## Exit criteria

| Criterion (plan, Phase 1 Sprint 1) | Result |
|---|---|
| `crossbuild-runner` pass-1 builds the wasm cross-compiler | `obj/xbuild/wasm/xc.core`, 51 MB, built from the new backend |
| genesis pass 1 writes headers | `src/runtime/genesis/sbcl.h` carries `LISP_FEATURE_WASM`, `LISP_FEATURE_SOFT_CARD_MARKS`, `N_WORD_BITS 32`, `BACKEND_PAGE_BYTES 32768`, `CARDS_PER_PAGE 32`, `GENCGC_CARD_BYTES 1024`, `STATIC_SPACE_START 0x1100000`, `ALIEN_LINKAGE_TABLE_ENTRY_SIZE 4` |
| assembler unit tests pass, every emitted module validated by wasm-tools | 27 Lisp-side checks, 4 modules validate with `--features all`, 5 exported functions run under wasmtime with the expected results, name section present |

Regression: `make-host-1` for x86-64 still succeeds with the generic edits
(`check-x86-64-host1.sh`).

## What was verified about the design

**Encoder correctness.** LEB128 edge cases (0, 63, 64, -64, -65, 127,
128, -1, 624485, -123456) match the specification's worked examples;
`i32.const #xFFFFFFFF` encodes as the signed `-1` form the format
requires; the five-byte fixed encoding is accepted by both validators and
engines, which is what makes load-time patching of `i32.const` immediates
possible without changing instruction sizes.

**Structured control flow and calls through the encoder.** The `arith`
module exercises `block`/`loop`/`br_if`/`br`, `if`/`else` with a result
type, `br_table`, `select`, a `call_indirect` through an element segment,
and mixed-width memory access; wasmtime computes the value the Lisp side
computed. The `eh` module's `try_table`/`throw` and a 10^6-deep
`return_call` run correctly, confirming the encoder for the two Wasm 3.0
features the design depends on (S0.2 established engine support; this
establishes that this assembler emits them right).

**Control pseudo-instructions.** Zero-size back-patches record the notes
at their final positions, in emission order, with the labels marked used.
Codegen consumes labels through sections, so this is the path the
function assembler (Sprint 3) will read: a byte vector plus label
positions plus notes, with no re-decoding of the byte stream.

**The front end's demands on a backend are larger than the plan assumed.**
The plan's Sprint 1 expected the VOP files to be stubs. In fact
`make-host-1` fails unless the backend defines, at load time: move
functions for every storage class (checked when *any* VOP is defined),
the VOPs the front end names in `vop`/`vop*` forms and `#.` reads (about
120, including macro-generated ones such as the `define-full-call`
family and the raw-slot accessors), the `defknown`s for
`floating-point-modes` and `receive-pending-interrupt`, the frame-location
hooks, `convert-conditional-move-p`, `emit-error-break`,
`fixup-code-object`, and the `%test-*` type-test helpers. Anything
missing shows as a compile error; anything duplicated with a generic
definition shows as a duplicate-VOP error; and any residual
style-warning fails the build. The skeleton generator turned that into a
mechanical process, and the resulting files double as the exact worklist
for Sprint 3: 529 `define-vop` forms of which about 480 have placeholder
generators.

**A generic assembler quirk worth knowing.** `process-back-patches`
drops the second of two zero-size back-patches when the segment has no
leading origin label, which is the case only for a raw segment assembled
without a section. All real assembly goes through sections and
`%assemble`, which emit the origin label first; the module writer's
`assemble-octets` now does the same. No generic change was needed.

## Decisions taken

- **Register access is a two-macro seam** (`load-reg`/`store-reg`): every
  VOP written from now on goes through them, so caching registers in Wasm
  locals (Sprint 12) stays a local change.
- **Frames gain a code slot** (`code-save-offset` 2) in addition to the
  return-point descriptor, per design 2.4, so the debugger can find a
  frame's code object without a return address.
- **No `zero` storage class.** riscv's constant-zero register has no
  analogue; `immediate` covers it.
- **`:soft-card-marks` is on from the start**, so that the store-barrier
  VOPs are written once, in Sprint 3.
- **Modular arithmetic** VOPs are not carried over from riscv (they name
  riscv-specific `-modxlen` functions); Sprint 3 defines `-mod32`
  functions in the x86 style.
- **Float immediates are bit patterns** in the instruction set, because
  the cross-compiler's floats are not the host's.

## Further study (feeds Sprint 3)

1. `assemble-sections` (`assem.lisp:1566`) appends a simple-fun offset
   trailer and asserts lowtag alignment: the code component's byte
   layout on this target (design 2.2: no instructions in the heap) needs
   a `#+wasm` path in `generate-code` that hands the segment bytes, label
   positions and control notes to the function assembler and stores
   table indices instead. Decide in Sprint 3 whether the trailer is kept
   (harmless) or replaced.
2. `%test-headers` and the header-word load will need the
   `other-pointer-lowtag` check as an `i32.and`/`i32.eq` sequence and a
   range test on widetags; write it as a shared helper since the array
   and type VOPs all use it.
3. The register-file address inside the thread struct is symbolic
   (`register-byte-offset` = slot × word size from `$thread`); the thread
   primitive object gets `#+wasm` slots for the 32 word and 32 float
   registers in Sprint 3, and `register-byte-offset` becomes
   `(thread-slot-offset 'register-area)` plus the slot displacement.
4. The skeleton generator (`gen-skeletons.lisp`) can regenerate any VOP
   family from a riscv32 image at any time; it should not be run over
   files once their real generators exist.
