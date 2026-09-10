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

## 2. Tuning the flush and reload sets

(filled in after the first measurement)

## 3. The calling convention

(the plan's second half: arguments as parameters, `A0` as the result)

## 4. The build and the measurements

(filled in)
