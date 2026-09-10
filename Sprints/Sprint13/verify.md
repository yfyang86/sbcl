# Sprint 13 — verification and further study

## 1. Exit criteria (the plan's "Sprint 12: register caching and calling convention")

| Criterion | Result |
|---|---|
| registers cached in Wasm locals between flush points, the register area the truth at function boundaries and runtime calls | met: `reg.get`/`reg.set` locals per register, the flush and reload notes of every call, return, throw and runtime entry, the per-function mask of uses (`develop.md`, sections 1–2) |
| the first arguments as Wasm parameters, `A0` as the Wasm result | half met: NARGS and A0..A3 are the parameters of the Lisp function type `(i32 i32 i32 i32 i32) -> (i32)`; the result stays the values flag, `A0` returns through the area — the C runtime cannot take a multi-value result through a function pointer, and a trampoline for its calls is the next step (section 3) |
| `return_call_indirect` for tail calls | met since Sprint 4; the parameters ride on it |
| the suites clean | met against Sprint 12's baseline (`test.md`): the regression suite differs by two tests that pass now; the ANSI suite by one randomized test, exempted as upstream exempts it; the two failures the sprint introduced (the collector's exact register roots, the save's re-lowering) are fixed and the suites re-run on the fixed build |
| compute-bound cl-bench within 3× of native under Wasmtime and V8, in `baselines/` | **not met** under Wasmtime (`doc/wasm-port/baselines/sprint-13-cl-bench.md`, section 4): the array, float and bignum loops are within 1.2–3×, the call-heavy kernels 5–25× (`fib`, `tak`, `ackermann`) and the two that go through the runtime's unwind or 32-bit bignums 80–100× (`ctak`, `crc40`). Not measured under V8: the port has no JavaScript host yet (`SBCL-Handoff.md`); recorded as such |

## 2. What the sprint taught

- **A cache needs one owner for every value at every point.** The
  register cache's rule was simple until the parameters gave five
  registers two homes: the local at entry, the area after a callee's
  return. `identity` (a parameter returned untouched) broke the first
  build, the fix for it broke `more-arg-values` (a callee's result
  returned untouched), and the rule that holds treats the five as used
  by every function. A pass-through is a use the code never records.
- **Precise roots must be precise.** The collector took the register
  area's words as exact roots since Sprint 8, and nothing failed for
  five sprints because compiled code rewrote every register within a
  few instructions. The cache made a stale word ordinary; the failure
  came in the one run that allocated enough between two uses of a
  register — the benchmark at full scale, not the suites — and needed
  an instrumented runtime to find (a watch on one page's accounting,
  the pin sources logged). An assumption about how often memory is
  written is not an invariant.
- **The suites are not the only test.** Two of the sprint's three
  real bugs (the exact roots, the save's heap) were found by the
  benchmark at scale 1 and by the measurement plan, not by 403 files
  and 21,752 tests. The compute-bound subset at scale 1 joins the
  sprint checks.
- **Measure the parameters before believing in them.** The convention
  change was the plan's headline and measured 0.98: what it saved, the
  mask rule spent, and the call's cost is elsewhere (`develop.md`,
  section 4). The next sprint starts from the count of memory
  operations per call, not from the convention.
- **Rebuild the rig with the type it tests.** A stale level-1 driver
  produced 444 failures with a message ("type mismatch with
  parameters") that read like a compiler bug; the build driver's
  `host` step builds it now.

## 3. Open items (the backlog)

1. **The call sequence** (`develop.md`, section 4): the XEP and the
   body in one Wasm function (or the body's entry taking the XEP's
   locals), a prologue that loads only what is read before it is
   written, `A0` as the result with a trampoline for `call_into_lisp`,
   the fixnum fast path of the generic arithmetic inline. The
   call-heavy kernels are 5–25× the host; the loops 1.2–3×.
2. **`ctak` and `crc40`**: `catch`/`throw` through the runtime's
   unwind (100×), and `(unsigned-byte 40)` arithmetic in bignums on a
   32-bit word (80×); the second is the target's, the first a cheaper
   unwind (the catch block's function as the handler, without the
   runtime).
3. **The float registers** stay in the area (`develop.md`, section 1);
   the float kernels are within 2× and would gain what the integer
   ones did.
4. **A JavaScript host**, for the V8 half of the exit criterion and
   the Node.js integration (`SBCL-Handoff.md`).
5. **`FORMAT.E.26`**: fails on the port as it does upstream, at
   random; exempted, not understood.
6. Carried: the remaining stackifier fallbacks (34 + 61), the
   debugger support, dynamic-extent allocation, `FILE-LENGTH.ERROR.3`,
   `block-compile.impure.lisp` (passing now, watched).
