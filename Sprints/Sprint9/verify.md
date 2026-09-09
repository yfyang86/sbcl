# Sprint 9 — verification and further study

## 1. Exit criteria (plan Sprint 8, "self-hosting and the first baseline")

| Criterion | Result |
|---|---|
| `compile-file` and `load` of fasls | met: `test.md`, "compile-file, load, disassemble" (a file compiled by the saved core, loaded, called) |
| `disassemble` | met: prints the Wasm of a loaded function and of a core function (`src/compiler/wasm/target-insts.lisp`) |
| the pure-Lisp contribs (`asdf`, `sb-rt`, `sb-md5`, `sb-cltl2`, `sb-rotate-byte`, `sb-aclrepl`, `sb-executable`, `sb-queue`) | met: `./build-wasm.sh contrib` builds them (and `sb-concurrency`, `sb-introspect`, `sb-cover`); `require` loads each in the saved core |
| `tests/subr.sh` and `run-sbcl.sh` routing through `sbcl-wasm`; `parallel-exec.sh` under Wasmtime | met: `tools-for-build/wasm-sbcl.sh` is the runtime the scripts run; `tests/wasm-parallel-exec.sh` runs the files N at a time on the host |
| `tests/run-tests.sh` runs to completion and produces the first baseline report listing every failing test | met: `doc/wasm-port/baselines/sprint-8.txt` (403 files: 295 passed, 108 did not; 161 unexpected failures reported by name, 5,520 successes; the run took 44 minutes with three processes and a 900 s deadline per file) |
| `tests/ansi-tests.sh` runs to completion | met: 21,752 tests in 48 processes, 21,539 pass, 192 fail, 21 crashed (in the report) |

## 2. What the suites say

The baseline is the deliverable of this sprint and the input of the
next two ("triage and fix"): a list, not a pass. Its failure classes,
from the per-file logs (`develop.md`, section 7):

1. **Foreign calls whose Lisp signature disagrees with wasi-libc's**
   (`indirect call type mismatch`, the most frequent way a file died:
   22 of the first run's files, among them `aliencall`, `debug`,
   `deadline`, `float`): a machine target misreads the arguments;
   Wasm's typed `call_indirect` refuses. In the ANSI suite `sleep`
   (`nanosleep`), `file-author` (`getpwuid` through `uid-username`)
   and `machine-instance` (`gethostname`) die the same way. Each is a
   `define-alien-routine` to reconcile with the C prototype (64-bit
   `time_t`, `size_t`, pointer results), or a linkage cell holding a
   data symbol where a function is called.
2. **Backend traps in compiled test code** (`unreachable`, 6 files:
   `arith`, `arith-2`, `arith-slow`, `hash` and others; in the ANSI
   suite `symbol-value.error.5`, `makunbound.2`, `eval.error.4`,
   `cell-error-name.1`, `elt-v.10`). The instruction is what the
   backend emits where a VOP has no code path for a case (an unhandled
   type or storage class), so each trap names a VOP to finish; the
   offset in the trap backtrace and `disassemble` find it. One file
   died of an `out of bounds table access` (a call through an index no
   module provides).
3. **What WASI lacks or the port has not got**: `setitimer`
   (`timer.impure.lisp` waits for the deadline), signals
   (`signals.impure.lisp`), `sb-posix` (blocklisted; `signals` and
   `run-program` `require` it), executable cores (`banner.test.sh`
   runs the saved file as a program, "Exec format error"),
   symbolic-link and ownership queries (`filesys.test.sh`), the
   debugger under `--disable-debugger` (the ANSI `invoke-debugger`
   tests end the process, by design), and `genheaders.test.sh`, which
   regenerates the headers from the host build's
   `local-target-features.lisp-expr` (Linux features) and diffs them
   against the crossbuild's.
4. **Reported failures** in the runner's own format (`Failure: file /
   test`): `clos`, `compiler`, `reader` (consing checks),
   `dynamic-extent` (not honoured, Sprint 4 carry-over), the float
   printers (`print.*-float`, `format.e`, `format.f`) and `sxhash` in
   the ANSI suite (the 32-bit word and the missing `dynamic-extent`
   account for some; each needs a look). The first run reported no
   unexpected successes.

## 3. Open items

1. **The traps** (classes 1 and 2 above) are the Sprint 10 backlog; the
   report lists every file and test. A host trap handler that turns a
   `call_indirect` type mismatch on a linkage cell into the Lisp
   `undefined-alien-error` (Sprint 8, item 6) would make class 1 a
   Lisp error instead of a process death.
2. **`sb_setitimer` and signals**: the host could deliver a timer
   through the pending-interrupt word it already sets for Ctrl-C
   (`SBCL_WASM_TIMEOUT` uses the same path); `timer.impure.lisp` and
   `deadline.impure.lisp` would then run.
3. **Executable cores**: `save-lisp-and-die :executable t` writes the
   runtime and the core into one file that the host cannot run. Either
   the host learns to run a core with an embedded module, or
   `:executable` writes a shell wrapper next to the module.
4. **`run-program` is synchronous**: `:wait nil`, `:stream`, `:pty` and
   signals to children are unsupported (`develop.md`, section 2); the
   tests that need a background child (`run-program.impure.lisp`) fail.
5. **The regression suite takes 44 minutes** with three processes and
   a 900 s deadline per file (the ANSI suite 20 minutes): each file
   starts a saved core (about four seconds with its 7,000 modules)
   and the impure files a second one. Merging the saved modules (Sprint 8, item 7) would cut the
   startup; the parallel runner could also keep one warm process per
   pure file group.
6. **`*random-state*` is the same at every start** of a saved core
   (`develop.md`, item 11): with the host's pid the scratch names no
   longer collide, but `seed-random-state` from the host's clock or
   `random_get` at `reinit` is what the other targets effectively get
   from their own pids and should be considered.
7. Carried from Sprint 8: the one-off trap at the end of a warm compile
   (not seen again in this sprint's builds and runs), the C shadow
   stack after a non-local exit through C frames, the 512 MiB default
   heap, the safe point only at function entry, `dynamic-extent`.

## 4. Further study

- The trap classes above are best worked from the report's list by
  frequency of the trapping VOP, not by test: one VOP fix clears many
  tests. `SBCL_WASM_DUMP_INSTALLED=1` with `wasm-func.py --module`
  names the VOP from the trap offset in a run-time module.
- The ANSI failures that are the same on the 32-bit x86 port (the
  suite's known failures for `x86` and `arm`) should be separated from
  the port's own before triage; the suite's `ansi-tests.sh` prints
  that list for other targets.
