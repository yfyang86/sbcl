# Sprint 11 — development notes

Plan: `doc/wasm-port/04-sprints.md`, "Sprint 9–10: triage and fix", the
second sprint; the backlog: `Sprints/Sprint10/verify.md`, section 3. No
hour-long suite runs and no UAT this sprint: each item is validated on
the test files it concerns (`test.md`).

## 1. The ANSI suite's state-dependent failures: the writer found

The evidence of the last sprint (`Sprints/Sprint10/develop.md`, section
9) ended at "something in the C side's memory has changed". This
sprint's steps, in order:

1. **Layout dependence.** With a 512 MB heap the generator's answer
   changes at test 1,170 instead of 1,251, and to "(s" instead of "()";
   with 4 MB canary regions placed around the thread block at 1,272. A
   logical state would not move; a stray write whose victim depends on
   what sits where does.
2. **The stacks are innocent.** The control, binding and number stack
   pointers are where they were after every test (`ansi-csp.lisp`); the
   canaries around the thread block (control, binding and alien stacks,
   the thread struct; `SBCL_WASM_CANARY=1`, `wasm_check_canaries`,
   wasi-mman.c) never change.
3. **The statics.** Watching the runtime's `.rodata`, `.data` and
   `.bss` (minus the register area and the number stack) after every
   test (`ansi-snap.lisp`, addresses from a linker map of the runtime)
   shows the generator's format strings, at the start of `.rodata`
   (address 0x400), being overwritten from test 1,039 on, one word pair
   per test at ascending addresses: `(NIL . other-pointer)` pairs whose
   pointers descend into the C stack by 288 bytes each, in bursts of
   up to eighteen in one test. The tests are the chapter's
   `.error` tests (wrong argument counts, `make-symbol`,
   `copy-symbol`, `gensym`), which raise ten to twenty internal errors
   each. The first 128 pairs went below 0x400, unobserved. The
   generator (`lisp_perfhash_with_options`) prints through those
   strings, so "()" and the undecodable bytes are what `printf` makes
   of overwritten formats.
4. **Not reproducible in isolation**: the same tests in a fresh process
   write nothing at 0..0x400, so the writing pointer starts elsewhere
   and reaches the low addresses only in a long run; the writer is found
   with `SBCL_WASM_WATCH=400` (wasm-arch.c), which reports the runtime
   entry point at which the word changes.

5. **The watch run and what it found.** `SBCL_WASM_WATCH=400` over the
   whole chapter reported nothing: with the runtime relinked for the
   watch (its `.rodata`, `.data` and `.bss` a few hundred bytes
   different), the generator's answer did not change in 4,610 tests,
   and a snapshot of the whole low memory (0..0xc150, the null page
   included, `ansi-snap2.lisp`) changed in one word only, a counter in
   `.data`, over 2,058 tests. The stray write's victim moved with the
   layout, as step 1 predicted; where it went is not known.
6. **The check that matters.** The whole suite, 21,752 tests, in one
   process against the current runtime (`ansi-oneproc.lisp`, the four
   `INVOKE-DEBUGGER` tests left out because they end a
   `--disable-debugger` process): 146 failures, of which 4 are not in
   the expected list, all four environment-specific to the
   one-process run (`ENSURE-DIRECTORIES-EXIST.8`, `LOAD-PATHNAME.1`
   and `LOAD-TRUENAME.1` from the changed default directory,
   `FORMAT.E.26` which `ansi-tests.sh` itself discounts), and one
   expected failure passing (`FILE-LENGTH.ERROR.3`). The 55
   state-dependent failures of the last baseline are gone in this
   build.

The honest summary: the failures are not reproducible in the current
runtime, and the writer has not been identified. The mechanism is
understood well enough to catch it when it comes back: the pattern
(cons-sized pairs of `NIL` and a pointer into the C stack, one per
nested internal error, at an address that advances by eight bytes per
error from somewhere below the runtime's data), and two detectors that
cost nothing when they are off: `SBCL_WASM_WATCH=HEXADDR` and the
canaries of `SBCL_WASM_CANARY=1`, which now include the null page
(0..0x3ff, which nothing maps) and are checked after every collection.
The item stays on the backlog as "find the writer of the nested
internal error pairs" with the diagnostics scripts in
`Sprints/Sprint11/` and the evidence above.

## 2. Executable cores

`save-lisp-and-die :executable t` writes a launcher: a `#!/bin/sh`
script that runs the host and the module that saved it with the
script's own name as the guest's `argv[0]` (`SBCL_WASM_ARGV0`, honoured
by the host), followed by the core with the embedded-core trailer, so
`main` finds the core in `argv[0]` as it does for a native executable
(before `os_init`'s chdir, so a relative name is resolved by hand). The
host names itself and the module to the guest (`SBCL_WASM_HOST`,
`SBCL_WASM_RUNTIME`), the runtime's `*runtime-pathname*` stays the
module, `*posix-argv*` names the launcher, the saved runtime options
apply, and the core module is copied beside the launcher as for any
core. WASI has no `chmod`: the file is not executable until `chmod +x`,
which the tests do themselves. `banner.test.sh` and `save6.test.sh`
pass; `save7.test.sh` failed at every memory-size assertion, which
led to a bug of its own: `(extern-alien "thread_control_stack_size"
unsigned)` read 0 through the evaluator (the test's forms come from
stdin) and the right value when compiled. On this target
`FOREIGN-SYMBOL-ADDRESS` returns the linkage cell's content (the
variable's address; a cell is not a trampoline here, see foreign.lisp),
and `FOREIGN-SYMBOL-SAP` dereferenced it a second time for a data
symbol, reading the variable's value as an address; compiled code goes
through the `FOREIGN-SYMBOL-DATAREF-SAP` VOP and was right. Fixed in
`FOREIGN-SYMBOL-SAP`; `save7.test.sh` passes.

## 3. The stack guards

There are no guard pages (design 2.x: linear memory has one
protection). The guards are explicit limits in the register area:
`+thread-control-stack-limit-offset+` (472) and
`+thread-binding-stack-limit-offset+` (476), set by the runtime at the
first `call_into_lisp` to the stack's end less a guard zone (64 KB and
16 KB). Compiled code compares CSP with the limit at every frame
allocation, the safe point of every entry (`EMIT-SAFE-POINT`, now one
test of "interrupt pending or CSP past the limit") and the frames of
local calls (`ALLOCATE-FRAME`, `EMIT-STACK-CHECK`: a self-recursive
local function never passes an entry point), and the binding stack
pointer with its limit in `DYNBIND`; past the limit the code calls the
runtime's `pending_interrupt`, whose `check_stack_guards` (wasm-arch.c)
does what the guard-page handler does elsewhere: a guard already
lowered is fatal ("fault in the guard handler"), otherwise the limit
moves to the stack's hard end so the handler has room, the `GUARD` bit
of the interrupt-pending word makes every entry poll, and the Lisp
error function (`CONTROL-STACK-EXHAUSTED-ERROR`,
`BINDING-STACK-EXHAUSTED-ERROR`, static symbols) is called with the
registers saved as an interrupt context, as the collector is called
from the safe point; once the stack has shrunk back below a return
zone (16 KB and 4 KB under the soft limit) the guard is restored and
the polling stops.

Before this a runaway recursion wrote through the binding stack, the
thread struct and hundreds of megabytes of heap before Wasmtime's own
"call stack exhausted" trap (the Wasm stack is 128 MB, the control
stack 2 MB); now `(handler-case (recurse) (storage-condition () ...))`
answers, twice in a row, and `exhaust.impure.lisp` passes
(`:basic`, `:non-local-control` with its hundred exhaustions,
`:restarts`, `:binding-stack`; the two Windows-only tests and
`:alien-stack` are skipped by their own tags).

## 4. Timers through the host

WASI has no interval timers and no signals. `sb_setitimer` (wrap.c)
keeps the one `ITIMER_REAL` deadline itself and asks the host for a
tick when it is due (`sbcl_host.set_timer`, microseconds; 0 cancels): a
host thread sleeps until then and, unless a later call superseded it,
makes Wasmtime's epoch callback set the `TIMER` bit (16) of the
interrupt-pending word; the safe point of the next entry calls
`RUN-EXPIRED-TIMERS` (a static symbol now) with the registers saved,
or, with interrupts disabled, sets `*interrupt-pending*` and leaves the
bit set so that the exit of the `WITHOUT-INTERRUPTS`
(`RECEIVE-PENDING-INTERRUPT`, the same import) delivers it, as the
deferred `SIGALRM` handler would. A sleep is cut into slices at the
deadline (`sb_nanosleep`), and the timers run from the slice's end, a
foreign call being a safe point as well, so `(with-timeout 0.5 (sleep
3))` signals at half a second as the interrupted `nanosleep` would.
`RUN-TIMER` calls the timer's function here as `INTERRUPT-THREAD` would
have run it (with interrupts disabled under `ALLOW-WITH-INTERRUPTS`);
`:thread t` timers, which need a thread, are an error.
`timer.impure.lisp` is untagged; the deadline tests that wait on a
child process keep a tag (the host runs the child and waits for it, so
no deadline can interrupt the wait: `run-program :wait nil` is on the
backlog).

The first `timer.impure.lisp` run hung in `:deferrables-blocked`: its
`(loop until finishedp)` waits for a timer with no call in the loop, so
no safe point was ever reached (the "safe point only at function
entry" item carried since Sprint 8). The function assembler now makes
a backward block branch a safe point too (`EMIT-BACK-EDGE-POLL`: the
interrupt-pending word tested, `pending_interrupt` called when set: a
load and a branch per iteration). The first version polled at every
backward jump, including those inside a VOP (the argument-copying and
values loops of call.lisp, values.lisp): the warm compile then died in
the type system with a collection run from such a loop, whose values
are in Wasm locals or half-moved on the stack; only the branches the
compiler emits between its blocks qualify: `GENERATE-CODE` binds
`*BLOCK-BRANCH-P*` while the generator of `BRANCH` or of a
`:conditional` VOP runs, and the assembler marks their jumps `:poll`
on the control note (most conditional VOPs emit their `jump-if`
themselves; the first version marked only `EMIT-CONDITIONAL-BRANCH`'s
and missed the loop of `(loop until x)`, whose back edge is the test's
own branch). That flag never reached the emitters either (the reason
was not found: the binding is in the compiled `GENERATE-CODE`, the
emitters read `NIL`), so the decision is structural in the end: the
compiler already hands the function assembler its blocks' labels
(`*wasm-block-labels*`, for grouping by environment), and a backward
branch whose target is one of those labels is a block edge; a branch
inside a VOP targets a label of its own.

A false alarm on the way: the ANSI suite would not load into the new
core ("invalid number of arguments" from its own `handler-case`
macro), which looked like a compiler regression until the suite's
`compile-and-load` turned out to load the fasls it had compiled with
the previous build (a fasl newer than its source is not recompiled);
`wasm-ansi-tests.sh` now deletes the suite's fasls whenever it rebuilds
its core.

## 5. One module per saved core

A warm load's core carried 7,138 modules, one per code object loaded
at run time, instantiated one by one at every start (each a
compilation, cached, and a memory mapping; the mapping count is why
`vm.max_map_count` is raised for the suites). `WASM-INSTALL-CODE` now
keeps the compiler's blob (smaller than the module made from it, and
carrying the patch tables) in `*wasm-code-blobs*`, and `DEINIT` lowers
every blob into one module (`WASM-MERGE-LOADED-MODULES`: the routine
imports of all, then each blob's functions at their table range, the
same patching as at install time, one element segment per blob), which
becomes the one entry of `*wasm-loaded-modules*`; the runtime's startup
is unchanged. The blobs stay for the next save. The first saved core
trapped at its first symbol lookup: the packages' perfect-hash
functions are compiled on the way to the core file, after `DEINIT`, and
the version that kept only blobs lost their modules; installs keep
their module in `*wasm-loaded-modules*` as well, so a core saved after
the merge carries the merged module and the few compiled after it.

## 6. The rest

- `linux-wasm.yml`: the tool chain (pinned versions, downloaded by
  `build-wasm.sh toolchain`), the host, the cross build, the runtime,
  the warm load, the contribs, the level-0/1 tests and both suites, on
  push; logs uploaded.
- `poll` on files: wasi-libc's `select` (the `#-os-provides-poll`
  path, behind `poll_oneoff`) fails on a regular file ("select(2)
  failed on fd 6": `LISTEN.7`, `external-format`'s `:end-of-file`).
  `:os-provides-poll` was tried first: wasi-libc's `poll` works on
  files but fails with `EBADF` on the standard descriptors under
  Wasmtime, which stopped the warm load's reading of its script; so
  `UNIX-SIMPLE-POLL` answers "ready" for a regular file (an `fstat`)
  and asks `select` for everything else, as before.
- `file-author` answers `NIL` where WASI has no user database
  (`FILE-AUTHOR.1-7` expect `(or null string)`).
- The test-side stubs `check_deferrables_*_or_lose` and the variable
  `lose_on_corruption_p` joined the kept linkage names.
- Not done: the `arith-2` arithmetic bugs (four tests) and
  `INVOKE-DEBUGGER.1` under `--disable-debugger` stay on the backlog.
