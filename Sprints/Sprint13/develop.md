# Sprint 13 — development record (register caching and the calling convention)

Plan: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 12: register
caching and calling convention" (the directory numbering is one ahead
of the plan). Design: `doc/wasm-port/02-design.md`, 2.4.

## 1. The register cache

Until this sprint every register access of compiled code was a memory
access: `load-reg` expanded to `global.get $thread; i32.load
offset=4n`, `store-reg` to the store, one per operand of every VOP
(Sprint 12's record measured what that costs: the stackifier's 1.18
where control flow alone had promised 2). The design's seam holds:
the two macros now expand to `reg.get` and `reg.set` (insts.lisp),
which are `local.get`/`local.set` of a Wasm local per register slot,
the first 32 locals of every Lisp function
(`+register-locals-base+`; the scratch locals, `$pc` and the rest
moved up by 32). The register area of the thread structure stays the
truth wherever anything but the function's own code looks at it:

- **Entry.** The prologue reads every register the function touches
  from the area into its local (`emit-reload`), after the `$fp` load
  and before the entry-arm dispatch, so every entry — the start, a
  local call's arm, a non-local entry — sees the area's values. The
  exception handler of a function with non-local entries reloads
  before it branches to the target arm: the unwind routine set the
  block's frame and code in the area.
- **Flush points.** The instruction emitters of `call`,
  `call_indirect`, `return_call`, `return_call_indirect`, `return`,
  `throw` and `throw_ref` emit a `:flush` control note before the
  instruction and, where the instruction returns, a `:reload` note
  after it; the function assembler lowers a note into the stores or
  loads of the function's registers (or of the note's mask), the
  same way it lowers a branch note. Local calls (`:call-label`,
  `emit-cross-ref`) and the back-edge poll's `pending_interrupt` call
  get the same treatment from the assembler itself. Every runtime
  entry point is a flush point except the two allocation entries,
  which neither collect nor run Lisp (a collection waits for the next
  safe point; heap exhaustion signals through Lisp and does not
  return) and get only the frame registers (`+frame-register-mask+`:
  NARGS, CSP, CFP, OCFP, NFP, NSP, LEXENV, CODE), so that the
  collector's stack scan and an error's backtrace see the frame.
- **The used set.** `reg.get`/`reg.set` record the register and the
  emission position in the segment (`note-register-use`, filtered out
  of the control notes by `segment-control-notes`); `lower-functions`
  turns the records within a function's ranges into its `reg-mask`,
  the set the prologue reads and the flush points write. A function
  that touches 8 registers moves 8 words at each point, not 32.
- **Why this is enough for the collector.** Values live across a
  call are on the stack: the call VOPs are `:save-p t`, so `pack`
  spills them, and the frame registers the convention passes are in
  the flush set. A safe point (`pending_interrupt`) flushes every used
  register, live or not; a stale pointer in a dead register pins a
  dead object until it is overwritten, which the memory-resident
  registers did as well. The float registers stay in the area this
  sprint.
- **Outside the seam.** The foreign-call VOP stored a call's results
  into the register area directly; it goes through `store-reg` now
  (a 64-bit result splits into its two registers with `i64.shr_u`).
  The other direct reads of the thread area (the interrupt word, the
  stack limits, the float modes, the foreign cell) are not registers.

The first build passed levels 0 and 1 unchanged (16 checks, 444
argument sets). The code of a recursive function shows the shape: a
prologue of 15 loads (it touches 15 registers), a body of locals, and
15 stores before the `call_indirect` of the recursive call, 15 loads
after it, 15 stores before the `return` — which is where the tuning of
section 2 starts.

## 2. Tuning the flush and reload sets, and inline allocation

The first build (every flush point moving the whole used set) measured
1.27 on cl-bench's geometric mean against Sprint 12's core (63
benchmarks, a 1 GB heap — section 4 says why): the array and bignum
loops gained 2–4×, the call-heavy kernels lost 10–20% (`fib` 0.79),
as the shape of the code predicted. Three refinements, each a mask on
a note:

- A full call (`call_indirect` and `return_call_indirect` with the
  Lisp function type, index 0 in every module) writes back what the
  convention passes (the frame registers, RA; NARGS and A0..A3 until
  section 3 made them parameters) and reads back what the callee
  returns (A0..A3, NARGS, CSP, CFP, OCFP; NFP and NSP for the number
  stack). Nothing else is live across a full call: `pack` spilled it.
  The unknown-values `return` VOPs pass the same set to `return`; a
  known-values return and the local calls, whose values sit in
  whatever registers the caller chose, keep the whole set.
- The allocation entries get CSP and CFP only (the collector's stack
  scan, the heap-exhaustion error's frame), not the eight frame
  registers.
- Allocation itself moved inline: the free pointer of the main
  thread's mixed region sits at a fixed address in static space
  (`gencgc-alloc-region.h`; lists use the same region, there being no
  cons region on this target), so `emit-allocate` bumps it in place
  and calls the runtime only when the request does not fit — the
  native backends' scheme, with the runtime's `lisp_alloc` opening
  the next region and setting the collection pending. The runtime
  entry also cost a `getenv` per allocation (the allocation trace's
  switch, cached now).

Measured against Sprint 12's core, on the same 63 benchmarks:

| Build | Geometric mean | `fib` | `tak` | `boyer` | `deriv` | `3d-arrays` |
|---|---|---|---|---|---|---|
| the cache, every point the whole set | 1.27 | 0.79 | 1.02 | — | — | 4.1 |
| the masks | 1.35 | 1.13 | 1.02 | 1.42 | 0.93 | 4.07 |
| inline allocation | 1.49 | 1.09 | 1.22 | 1.61 | 1.56 | — |

The one loss that stays is `clos-defmethod` (0.58) and `clos-defclass`
(0.75): they compile methods at run time, and every function compiled
at run time is a module the engine compiles; the cached code is a
third bigger (the module of the cold core: 34 → 45 MB after
`wasm-opt`), and the engine's compile time goes with it.

## 3. The calling convention

The plan's second half: NARGS and A0..A3 are the parameters of the
Lisp function type, `(i32 i32 i32 i32 i32) -> (i32)`, the result
still the values flag. The register cache made this a renumbering:
the locals of those five registers are the first five (`register-local`
in insts.lisp maps a register to its local), which are the parameters
of every Lisp function, so a callee's prologue leaves them alone
(`prologue-reload-mask`) and a caller passes its own five locals
(`emit-lisp-call-args` in call.lisp for the full calls and the
assembly-routine calls, `emit-lisp-args` in the assembler for the
local calls). The five still exist in the area for the runtime — the
entry trace, `call_into_lisp`'s result — and are written there at
every flush point that moves the whole set; a full call's flush set
drops them. `call_into_lisp` passes them as C arguments; the level-1
rig calls its functions with them. `A0` as a Wasm result stays out:
the C runtime cannot receive a multi-value result through a function
pointer, and a single result can carry either the flag or `A0`, not
both; a trampoline in the core module would be the way, for a store
and a load per call.

The first build with the parameters passed levels 0 and 1 (once the
level-1 rig was rebuilt: `build-wasm.sh host` builds it now, with the
Wasmtime host) and died in cold init, in `hashset-insert-if-absent`
with a NIL key, its copier being `identity`. The entry trace put the
NIL where `identity` returned: `identity` returns its argument as it
came, so no `reg.get` or `reg.set` records A0, A0 is not in its
register mask, and its `return` wrote nothing to the area, from which
the caller reloads A0 — the NIL that `hashset-find` had just returned
there. The old convention hid this: the caller's flush before the call
put the argument in the area. A first repair, a `return` writing the
parameter registers of its mask from their locals regardless of use,
broke level 1's `more-arg-values` the other way round: its body
function gets the sum in A0 from the loop function's known return —
through the area — and never touches A0 either, so the forced store
wrote the stale parameter over the callee's value. A parameter
register a function does not touch has its truth in the local at
entry and in the area after a callee returns, and the function
assembler cannot tell which a value came from. The rule that holds:
the five parameter registers are in every Lisp function's mask of
uses (`lower-functions`), flushed at every flush point and reloaded at
every reload point like any register the function reads, with the
prologue the one exception (they arrive as parameters). A full call's
flush still leaves them out (the callee takes them as parameters), a
`return` writes the value registers (`+lisp-return-flush-mask+`; a
single value, `+lisp-return-single-flush-mask+`, A0 and the stack
registers), and a caller reloads them after the call. The cost: a
function that leaves A2 and A3 alone stores and loads them anyway at
its local calls and safe points, two words each way.

## 4. The builds and the measurements

Each build of the sprint went through pass-1 (34 s), the after-xc core
and levels 0 and 1, then pass-2, `wasm-opt`, the runtime, the warm
load and the contribs (`/tmp` scripts; about 12 minutes on the
container's four cores); the cores are kept as
`obj/wasm-build/sbcl-s13X.core`:

| Build | Change | Levels | Pipeline |
|---|---|---|---|
| s13a | the cache, every flush point the whole used set | 16, 444/444 | passed |
| s13b | the masks of a full call and a return | 16, 444/444 | passed |
| s13c | inline allocation, the allocation entry's mask | 16, 444/444 | passed |
| s13d | NARGS and A0..A3 as parameters | 16, 0/444 (a stale rig), 444/444 rebuilt | cold init: the `identity` pass-through (section 3) |
| s13e | a `return` forcing the parameter registers of its mask | 16, 442/444 (`more-arg-values`) | not run |
| s13f | the parameter registers in every mask | 16, 444/444 | passed; the suites of `test.md` |

The core module of the cold core: 34 MB after `wasm-opt` in Sprint
12, 45 MB with the cache (s13c), 44 MB with the parameters (s13f: the
argument flushes and prologue loads gone, the parameter registers'
flushes and reloads added); the warm load and the contribs took the
same 8 minutes as before.

Against Sprint 12's optimized core (`sbcl-s12opt.core`), 62–63
benchmarks, scale 10, a 1 GB heap (`obj/wasm-build/cl-bench/`,
`doc/wasm-port/baselines/sprint-13-cl-bench.md`):

| Build | Geometric mean | `fib` | `tak` | `ctak` | `crc40` | `boyer` | `3d-arrays` | `clos-defmethod` |
|---|---|---|---|---|---|---|---|---|
| s13a | 1.27 | 1.19 | 1.07 | 0.99 | 1.25 | 1.42 | 3.60 | 0.62 |
| s13b | 1.35 | 1.13 | 1.02 | 0.97 | 1.35 | 1.42 | 4.07 | 0.61 |
| s13c | 1.49 | 1.09 | 1.22 | 0.98 | 1.43 | 1.61 | 3.84 | 0.58 |
| s13f | 1.47 | 1.02 | 1.02 | 0.91 | 1.42 | 1.95 | 3.74 | 0.60 |

(s13c's numbers were taken while s13d was building, so the s13c/s13f
pair on an idle machine, `s13c-vs-s13f.txt`, is the one to read:
0.98.) The reading: the cache and the inline allocation are worth
half again over Sprint 12 across the suite, up to 3–4× on the array
and bignum loops; the parameters are worth nothing measurable. A
call still moves the same words through the area — the caller's
frame registers and RA before, the callee's values and stack
registers after, the parameter registers' round trip through every
mask — and what the parameters saved (an argument's flush and load
per call) the mask rule (section 3) spent again. The call-heavy
kernels sit where Sprint 12 left them, and `ctak` (`catch`/`throw`
through the runtime's unwind) a little below.

What a full call costs now, from the code of a two-argument
function calling another (`HI` in the probe of section 3): the
caller sets NARGS, OCFP, RA, CFP (four `local.set`), pushes the five
parameters and the entry index, stores seven words (the frame
registers, RA), `call_indirect` (a type check in the engine), loads
nine words (the reload set) and restores CODE from the frame; the
callee's XEP compares NARGS, computes CSP, checks the stack limit
and the interrupt word (two loads), moves the arguments to the
body's registers, stores its used set and `return_call`s the body,
which loads its used set again. Two flush-reload pairs and two
stack checks per call, some 40 memory operations, against the
native backend's handful of instructions: the gap on `fib` (section
5) is here, and the plan's next steps are the ones that cut it — a
body entered by the XEP without a second prologue (the XEP and the
body in one Wasm function, or the body's entry taking the XEP's
locals), a prologue that loads only what is read before it is
written, `A0` as the result through a trampoline for the C callers,
and the generic arithmetic's fixnum fast path inline (`fib`'s `+`
and `<` are assembly-routine calls with a flush and a reload each).

## 5. Against the host

(filled in from the scale-1 run of the compute-bound subset)
