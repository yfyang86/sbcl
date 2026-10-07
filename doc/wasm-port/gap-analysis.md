# Gap analysis: the plan against `wasm-dev` (2026-10-07, commit 3fb75a0)

What the plan (`04-sprints.md`) asked for, what the branch delivers,
and what remains — for the port's own exit criteria, for applications
that want native SBCL's capabilities, for the browser host, and for the
project's process. Sources: the sprint records under `Sprints/`, the
baselines under `baselines/`, the manual, and the tree at the commit
above (upstream level `2.6.8` per `version.lisp-expr`, master sync 3 of
2026-09-27).

## 1. Delivery against the plan, sprint by sprint

The sprint directories are numbered one ahead of the plan from Sprint 10
on (Phase 0's spikes took `Sprints/Sprint1`): `Sprints/Sprint13` is the
plan's Sprint 12, `Sprints/Sprint14` the plan's Sprint 14. The plan's
Sprint 13 has no directory.

| Plan | Record | State | Exit criteria not met |
|---|---|---|---|
| Phase 0 spikes S0.1–S0.7 | `Sprint1` | done | — |
| 1 target definition, assembler | `Sprint2` | done | — |
| 2 function assembler, simple VOPs | `Sprint3` | done | — |
| 3 calls, frames, allocation, floats, NLX | `Sprint4` | done | — |
| 4 genesis, fasls, core module | `Sprint5` | done | — |
| 5 runtime port, `sbcl-wasm` host | `Sprint6` | done | — |
| 6 cold init to the REPL | `Sprint7` | done | — |
| 7 GC and warm load | `Sprint8` | done | — |
| 8 self-hosting, first baseline | `Sprint9` | done | — |
| 9–10 triage and fix | `Sprint10`, `Sprint11` | done | "zero unexpected failures in both suites": met for the ANSI suite (0 unexpected since Sprint 13), **not for the regression suite** (section 2.1) |
| 11 stackifier, `wasm-opt` | `Sprint12` | done | cl-bench gain 1.18× against the predicted ~2× (the time was not in control flow); 34 + 61 functions still lower through the dispatch loop |
| 12 register caching, calling convention | `Sprint13` | done | `A0` as the Wasm result (half: parameters yes, result through the area); compute-bound cl-bench within 3× of native: **5.3× geometric mean** under Wasmtime, V8 not measured |
| **13 FFI and system contribs** | **none** | **not started** | alien callbacks, `sb-posix` on WASI, `sb-grovel` under `wasm_run`, `sb-sprof`, their tests — section 2.2 |
| 14 browser host | `Sprint14` | done | the Playwright step in CI had never passed (the server's path; fixed in commit 3fb75a0, section 5) |
| Phase 4 (distribution, wasm64, threads, SIMD, dynamic linking, debugger, upstreaming) | — | not started | section 4 |

Outside the plan and delivered: the master syncs (three, the last at
`baselines/wasm-dev-sync3.txt`), the perfect-hash journal workflow, the
browser host's input ring, the MOP gap response (section 6), the release
procedure (`WASM-Manual.md` 9, `WASM-NEWS.md`), `sb-js` as a skeleton.

## 2. The port's own gaps

### 2.1 The regression suite is stable, not clean

The ANSI suite is at the plan's bar: 21,752 tests, 0 unexpected
failures, 21 expected (the `#+wasm` list in `tests/ansi-tests.sh`), 4
crashes by design (`invoke-debugger`). The regression suite is not:

| Baseline | Machine | Files failing | Unexpected failures |
|---|---|---|---|
| `sprint-13.txt` | Linux container | 55 of 403 | 153 |
| `wasm-dev-sync3.txt` | Linux container | 53 of 404 | 153 (identical set) |
| `sprint-14-sync.txt` | macOS (the maintainer's) | 52 of 403 | 177 |
| `sbcl-wasm-proposal.txt` | macOS | 53 of 404 | 179 |

The set has not changed since Sprint 13 and every sync is checked
against it, so it is a known-failure list kept in the baseline files
rather than in the tree. The gap to the plan's "zero unexpected": the
153 tests are neither fixed nor tagged. The Sprint 10 triage
(`Sprints/Sprint10/triage.md`) classifies them by file; the classes that
remain are, by weight:

- **no stack allocation on this target**: `dynamic-extent.pure` (the
  largest file), the `no-consing` tests (`WITH-PINNED-OBJECTS` /
  `CACHED-TOKENIZED-STRING` flip between builds);
- **the debugger**: `backtrace`, `debug`, `step`, `disassem`
  (`sb-di` frame walking, stepping and breakpoints need code patching
  or an `lra`);
- **32-bit word and arithmetic edge cases**: `arith-2`, `float-2`,
  `hash-2`, `bit-vector`, `constraint`, parts of `compiler.pure`;
- **the compiler's notes and IR tests**: `compiler.impure`,
  `compiler-ir.pure`, `compiler.pure-cload`, `macro-policy-decls`
  (expectations written for native code sizes, notes and vop names);
- **the shell tests**: `filesys`, `hide-packages`, `run-program`,
  `run-sbcl`, `save2`/`save3`/`save8`, `script` (process semantics,
  signals, file ownership under the host);
- **alien callbacks**: `sb-introspect.impure` (fails on Linux, passed
  once on macOS — the only machine-dependent file).

Two further process gaps the baselines record: `threads.impure` can
hang the run for hours behind an orphaned child (the macOS runs), and
the machines disagree by about 25 tests (timing and host differences),
so no single number is "the" baseline.

**To close**: a sprint of the Sprint 10 kind over the 153 — fix what is
a bug (the arithmetic and bit-vector cases, the compiler-note
expectations where the port's output is reasonable), tag the rest with
`:skipped-on :wasm` and a reason (`no-stack-allocation`,
`no-debugger`, `no-signals`), so that `run-tests.sh` ends at zero
unexpected and CI can fail on a regression instead of comparing
reports by eye. The skip list was 139 forms at Sprint 11; the plan's
cap of 150 will need raising or the tags grouped per file.

### 2.2 FFI and the system contribs (the plan's Sprint 13)

Nothing of this sprint exists. The feature list is
`:gencgc :soft-card-marks :compare-and-swap-vops :wasm32 :wasi` — no
`:alien-callbacks`, no `:sb-thread`, no `:os-provides-dlopen`.

| Item | State | What it needs |
|---|---|---|
| alien callbacks | absent; `sb-introspect`'s test and `callback.impure` fail or are skipped | a callback is a Wasm function added to the funcref table whose body calls `call_into_lisp`; the C side gets a table index as the "function pointer". The host already grows the table (Sprint 6) and the module writer emits typed functions, so the pieces exist; `alien-callbacks.lisp` needs a `#+wasm` assembler routine per signature (fixed, few) and `invoke-with-saved-fp` semantics without a native stack |
| `sb-posix` | blocked (`build-wasm.sh`'s blocklist) | the WASI preview 1 subset (files, directories, times, `getenv`, `exit`); `fork`, `exec`, `wait`, signals, users, sockets, `mmap` documented as unsupported — the groveler is the blocker (below) |
| `sb-grovel` | blocked | the groveler compiles and runs a C program; under the port that is the wasi-sdk compiler plus `wasm_run.sh` (both in the tool chain already, used by `grovel-headers`); a `#+wasm` branch in `sb-grovel`'s `c-runner` |
| `sb-sprof` | blocked | sampling needs a timer that interrupts Lisp — the Sprint 11 timer path through the safe point delivers it; a `#+wasm` sampler without `SIGPROF` and with the port's frame walk |
| `sb-introspect`, `sb-cover`, `sb-concurrency` | build and load | their tests: `sb-introspect` fails on callbacks; the others untested in the records |
| `sb-simple-streams`, `sb-manual` | blocked | simple-streams wants `sb-posix`; the manual wants `texinfo` tooling, not a port issue |
| `sb-bsd-sockets`, `sb-simd`, `sb-capstone`, `sb-gmp`, `sb-mpfr`, `sb-perf` | blocked, as the plan intends | sockets wait for WASI preview 2 (Phase 4 item 5), SIMD for Phase 4 item 4 |

**To close**: run the plan's Sprint 13 as written; alien callbacks first
(they unblock `sb-introspect`'s suite and are the one FFI feature
applications ask for), then `sb-grovel` → `sb-posix` subset, then
`sb-sprof`.

### 2.3 Performance

`baselines/sprint-13-cl-bench.md` against native SBCL 2.4.8 x86-64 on
the same machine, compute-bound subset, Wasmtime:

| Class | Kernels | Slowdown |
|---|---|---|
| array, float and bignum loops | 8 within 3× (`3d-arrays` 1.1, `fft` 1.8, `deriv` 2.5) | 1–3× |
| mixed | 7 | 3–4× |
| call-heavy (`fib`, `tak`, `ackermann`, `boyer`, `frpoly`) | 16 | 5–25× |
| through the runtime | `ctak` (catch/throw via the unwind routine and the engine exception), `crc40` (40-bit arithmetic as bignums on a 32-bit word) | 80–138× |
| compile time of the benchmark files | | 7× (5.2 s against 0.7 s) |

The geometric mean is 5.3×, against the plan's 3×. The Sprint 13
record names the steps, in order of expected gain: the call sequence
(XEP and body in one function, prologue loading only what is read
first, `A0` as the Wasm result with a trampoline for the C runtime's
calls, inline fixnum fast paths of generic arithmetic); a cheaper
`catch` (the catch block's function as the handler, no runtime round
trip); float registers in locals (the area today); the remaining
dispatch-loop fallbacks. `crc40` is the 32-bit word's and stays until
wasm64 (Phase 4).

**Newly possible**: the browser host makes the V8 half of the criterion
measurable (`wasm/web/node-smoke.mjs` runs the port under Node). The
cl-bench driver has not been run under V8; that is a day's work and it
should precede the call-sequence sprint so both engines are in the
before/after.

### 2.4 Debugger and tooling

`backtrace` works for ordinary frames; `step`, breakpoints and
`disassemble`'s tests fail (no code patching, no `lra`). The manual's
section 6 covers the host-side tools (`wasm-coreindex.py`, the trap's
top frame, Wasmtime's `--debug-info`) and section 7 the source map. The
plan's Phase 4 item 6 (names section, DWARF for the runtime, DevTools
backtraces) is the formal home; `step.pure`, `debug.impure` and
`backtrace.impure` are in the 153 until then.

## 3. What an application does not get (the port against native SBCL)

For someone deciding whether to run an existing system on the port.
Each row is by design of the target or of this phase; none is a bug.

| Capability | Native SBCL | The port | Where it is heading |
|---|---|---|---|
| threads | `:sb-thread` | single-threaded; `sb-thread` API present, `make-thread` unsupported, `threads*.lisp` skipped | Phase 4 item 3 (Web Workers + shared memory, or `wasi-threads`) |
| signals, `interrupt-thread`, `with-timeout` across blocking C | yes | timers and deadlines via the host's epoch and the safe point; no asynchronous interruption of a blocking host call | the timer's latency is the Sprint 14 backlog item 4 |
| alien callbacks | yes | no | section 2.2 |
| `load-shared-object`, `dlopen` | yes | no; the linkage table is the fixed set from genesis plus wasi-libc; an undefined alien signals `undefined-alien-function-error` | Phase 4 item 5 (Wasm side modules) |
| sockets | `sb-bsd-sockets` | no | WASI preview 2 |
| `run-program` | `fork`/`exec` | through `sbcl_host.run_process` under the Wasmtime host; the browser host signals an error | stays host-defined |
| file system | the OS's | WASI preview 1 under Wasmtime (real files); an in-memory map in the browser (lost at page close) | Sprint 14 backlog item 2 (OPFS / IndexedDB) |
| dynamic-extent (stack allocation) | yes | no: `dynamic-extent` declarations are honoured by heap allocation | the records carry it; a Lisp-managed stack region is possible (the control stack is Lisp's) but not scheduled |
| word size | 64-bit | 32-bit (`wasm32`): 30-bit fixnums (63 on native), bignum arithmetic beyond it, 4 GB linear memory, no `mark-region` GC, no immobile space | Phase 4 item 2 (wasm64) |
| floating-point traps | hardware traps | none: `:no-float-traps`; overflow and invalid operations return infinities and NaNs per IEEE | by design of Wasm |
| SIMD (`sb-simd`) | yes | no | Phase 4 item 4 |
| `compile` at run time | native code in the heap | a Wasm module per component, instantiated by the host; thousands of them exhaust the engine's mappings (`vm.max_map_count` under Wasmtime), merged into one at save time | `compile-file` batching per file exists; a per-session merge is possible |
| deep recursion | the control stack's size | the port's control stack (configurable) and the engine's native stack for the C runtime; the deepest-recursion tests are skipped | — |
| the debugger | full | backtraces; no stepping, breakpoints or `sb-di` frame mutation | section 2.4 |
| `save-lisp-and-die :executable t` | an executable | a launcher script with the core appended (Wasmtime); nothing in the browser | Phase 4 item 1 (bundles) |
| startup | tens of ms | Wasmtime: hundreds of ms plus the module cache; browser: 0.2 s to the prompt in Chromium, 1.3 s in Firefox, after fetching 124 MB | Sprint 14 backlog item 3 |

## 4. The browser host (Sprint 14) against what a web application needs

Delivered: the worker, the WASI shim, the `sbcl_host` contract, the
input ring, the REPL page, four Playwright tests in Chromium and
Firefox, `sb-js` as a skeleton. The backlog in `Sprints/Sprint14/verify.md`,
section 3, in the order an application hits it:

1. **`js_call`** — Lisp cannot call JavaScript. `sb-js:js-call` signals
   its error until a runtime entry point exists (the mirror of
   `call_into_lisp`, values marshalled over linear memory, synchronous
   return via shared memory). Without it the browser port is a REPL,
   not a platform. This is the first thing to build.
2. **JavaScript calling Lisp** is the other half: today the page only
   feeds the REPL's standard input. An exported `funcall`-by-name with
   a result channel belongs to the same work.
3. **A persistent file system** — `compile-file` products and saved
   cores vanish with the worker.
4. **Caching** — 124 MB fetched and the 44 MB module recompiled on each
   load; `serve.mjs` deliberately sets `no-store`. A deployment wants
   `Cache-Control`, `WebAssembly.compileStreaming` and a smaller core
   (the Phase 4 bundle with compression; `wasm-opt -Os` on the core
   module beyond the current `-O2`).
5. **Interrupt latency** — Ctrl-C and timers reach a tight loop only at
   a clock read or poll; a `SharedArrayBuffer` flag polled at the safe
   point fixes it.
6. **Coverage** — Firefox runs only with `PLAYWRIGHT_FIREFOX=1` (not in
   CI); Safari is untested (its exnref and tail-call status decides
   whether the port runs there at all).

## 5. Continuous integration

`linux-wasm.yml` builds the tool chain, the host, the cross build, the
runtime, the warm load, the contribs, levels 0–1, the regression suite
(with `vm.max_map_count` raised), the ANSI suite and, since Sprint 14,
the browser suite. It had been green end to end on `wasm-dev` before
the browser step was added (runs for 7052623 and 6550efc); every run
since failed at "browser host tests" because the step started the dev
server as `node ../../wasm/web/serve.mjs` from `tests/wasm/web`, one
directory short of the real path, so Playwright found no server
(`ERR_CONNECTION_REFUSED`, run 37554375419). Commit 3fb75a0 starts the
server from the repository root, waits for the port instead of one
second, and uploads its log with the build logs. The suite passed
locally against the same server start with the container's Chromium
(4 of 4).

Remaining CI gaps:

- the regression step compares a report, not a pass/fail (section
  2.1); a regression shows up as a changed count, not a red job;
- the perfect-hash journal step is manual (`WASM-Manual.md` 8): a new
  pass-2 entry breaks CI until someone merges the recorded entry;
- one job of several hours on one runner; no nightly separate from
  push, no macOS job (the maintainer's runs are the macOS baseline);
- Firefox not in the browser step.

## 6. The MOP gap response

The ConsCell battery (`MOP-Coverage.md`) is answered in
`mop-gap-response.md` and merged (`f758a13`): items 1, 2, 5 and 6 done
and tested in-tree (`tests/mop-coverage.impure.lisp`, 0 unexpected),
items 3 (condition metaobjects) and 4 (`make-method-lambda`) declined
as upstream design work. The remaining steps are theirs: re-run
`pnpm run test:mop` on a build from `wasm-dev`, drop check 11's
`KNOWN-SBCL-GAP` tolerance, correct their item 2 list. The port's side
is closed unless items 3 or 4 move upstream.

## 7. Process and upstream

- **Upstream drift**: the tree is at `2.6.8` plus 112 picked master
  commits; each sync costs a day and finds one or two port fixes
  (`%make-lisp-obj`, `compute-old-nfp` last time). Monthly syncs keep
  that bounded; the backend's touch points outside `src/compiler/wasm/`
  (`genesis`, `dump`, `load`, `debug-int`, `codegen`) are behind
  `#+wasm`, as the risk register asked.
- **Upstreaming** (Phase 4 item 7) has not begun. The precondition the
  plan set — a clean regression suite — is section 2.1.
- **Records**: every sprint has `develop.md`/`test.md`/`verify.md`/`uat.sh`;
  the baselines are reproducible from `Sprints/Sprint9/baseline.sh`.
  The plan's sprint numbering and the directories' disagree by one from
  Sprint 10; a note in `04-sprints.md` or a rename would spare the next
  reader.

## 8. Recommended order

Each is a sprint of the existing kind, with the exit criterion from
the plan where one exists.

1. **Browser host round 2** — `js_call` both ways, persistent FS,
   caching headers; exit: a page that calls a Lisp function from
   JavaScript and keeps a compiled fasl across reloads. This is the
   application-facing gap and the one external users have asked about.
2. **The plan's Sprint 13** — alien callbacks, `sb-grovel` → `sb-posix`
   subset, `sb-sprof`; exit as the plan states.
3. **Regression suite to zero unexpected** — fix or tag the 153;
   exit: `run-tests.sh` reports 0 unexpected on Linux and macOS and CI
   fails on any new one.
4. **The call sequence** — measured under Wasmtime and V8 (cl-bench
   under Node first); exit: the call-heavy kernels under 5×, the
   geometric mean under 3× on at least one engine.
5. **Phase 4 item 1, distribution** — the bundle tool, core
   compression; it also serves item 4 of the browser list.

Phase 4's threads and wasm64 stay behind these: nothing above depends
on them, and both change the engine requirements for every user.
