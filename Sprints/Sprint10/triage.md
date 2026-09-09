# Sprint 10 — triage of the first baseline

Every file of `doc/wasm-port/baselines/sprint-8.txt` that did not pass,
with its class and the action taken or planned (plan Sprint 9–10: backend
bug, runtime bug, unsupported by design, floating-point traps, timing or
depth). "fixed" means fixed in this sprint; the rest names the sprint or
the tag. Counts: 108 files; the ANSI suite is in section 2.

| File | Ended | Failures | Class | Action |
|---|---|---|---|---|
| `aliencall.pure.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: libc or runtime function absent from the linkage table (`strdup`, `strcat`, `varint_unpack`, `gc_heapsort_uwords`, `hopscotch_*`, `gc_private_*`, `debug_function_name_from_pc` ...): now listed, and an undefined alien signals `undefined-alien-function-error` |
| `arith-2.pure.lisp` | trap: unreachable | 0 | backend | after the arm fix: five reported failures (`coerce :overflow` is no-float-traps; `:signed-byte-8-p-unsigned`, `:truncate-unknown-integer`, `:word-floor-ceiling`, `:logand-cut-constants.2` are arithmetic bugs to fix) |
| `arith-slow.pure.lisp` | trap:  | 0 | runtime | module exhaustion: thousands of run-time modules exhaust the host's executable mappings ("unable to make memory executable"); task 50 |
| `arith.pure.lisp` | trap: unreachable | 0 | backend | fixed: a jump to the first elsewhere chunk dispatched to the empty arm the function assembler makes at a range end (`arm-at`); the error path then ran `unreachable` |
| `array.pure.lisp` | trap: unreachable | 0 | backend | fixed: a jump to the first elsewhere chunk dispatched to the empty arm the function assembler makes at a range end (`arm-at`); the error path then ran `unreachable` |
| `backtrace.impure.lisp` | reported | 35 | debugger | frame walking: `backtrace`, `sb-di` frames, `restart-frame`, `return-from-frame`, stepping (breakpoints by code patching are impossible here, `debug.impure` dies of `lose`): `:broken-on :wasm` with the issue "debug-int on the wasm control stack" (Sprint 11) |
| `banner.test.sh` | reported | 0 | runtime | save: `:executable t` writes a file the host cannot run ("Exec format error"); Sprint 11: a launcher script with the core appended |
| `bit-vector.impure.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `block-compile.impure.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `brothertree.impure.lisp` | reported | 0 | foreign | fixed: `brothertree_*` were not in the linkage table (listed now) |
| `bsearch.pure.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: the runtime's `bsearch_*_uword` were not in the linkage table (listed now); not callbacks |
| `bug-1072739.pure.lisp` | trap: unreachable | 0 | backend | fixed: a jump to the first elsewhere chunk dispatched to the empty arm the function assembler makes at a range end (`arm-at`); the error path then ran `unreachable` |
| `ccase.pure.lisp` | reported | 1 | lisp | to look at individually (first failure in the log) |
| `chill.impure.lisp` | reported | 1 | environment | a C compiler, shared objects, the host's `make`, the crossbuild manifest, or `local-target-features` of the host build: `:skipped-on :wasm` (no-cc / environment) |
| `clos.impure.lisp` | reported | 2 | lisp | to look at individually (first failure in the log) |
| `cmp-combinations.pure.lisp` | trap:  | 0 | runtime | module exhaustion: thousands of run-time modules exhaust the host's executable mappings ("unable to make memory executable"); task 50 |
| `compare-and-swap.impure.lisp` | reported | 0 | backend | fixed: a jump to the first elsewhere chunk dispatched to the empty arm the function assembler makes at a range end (`arm-at`); the error path then ran `unreachable` |
| `compiler-2.impure.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `compiler-2.pure.lisp` | trap: indirect call type mismatch | 0 | runtime | the `pack-varints` call fixed; then module exhaustion at `:jump-table-use-labels`, with `arith-slow` (task 50) |
| `compiler-ir.pure.lisp` | reported | 2 | lisp | to look at individually (first failure in the log) |
| `compiler.impure.lisp` | reported | 2 | lisp | to look at individually (first failure in the log) |
| `compiler.pure-cload.lisp` | reported | 1 | lisp | to look at individually (first failure in the log) |
| `compiler.pure.lisp` | trap: unreachable | 0 | backend | fixed: the bit-vector store VOP computed its mask with `lognot` outside 32 bits for element 31 (`(compile bit-vector setf aref :overflow)`); the `i32.const` emitter refused it |
| `condition-2.pure.lisp` | reported | 1 | lisp | to look at individually (first failure in the log) |
| `condition.pure.lisp` | reported | 1 | backend | `dynamic-extent` is not honoured (no stack allocation in the backend; Sprint 4 carry-over): `:broken-on :wasm` for the no-consing and `stack-allocated-p` checks (issue "dx allocation") |
| `constraint.pure.lisp` | reported | 1 | lisp | to look at individually (first failure in the log) |
| `ctor.impure.lisp` | reported | 2 | lisp | to look at individually (first failure in the log) |
| `deadline.impure.lisp` | reported | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |
| `debug.impure.lisp` | reported | 0 | debugger | frame walking: `backtrace`, `sb-di` frames, `restart-frame`, `return-from-frame`, stepping (breakpoints by code patching are impossible here, `debug.impure` dies of `lose`): `:broken-on :wasm` with the issue "debug-int on the wasm control stack" (Sprint 11) |
| `debug.pure.lisp` | trap: indirect call type mismatch | 0 | debugger | after the fix: `debug_function_name_from_pc` is not compiled into this runtime; the rest passes |
| `defstruct.impure.lisp` | reported | 0 | debugger | after the arm fix: the "accessed uninitialized slot" message needs `sb-di:error-context` (the erring code location), which frame walking does not provide yet; the datum of the condition is the unbound marker, so it reads as unbound: with the debugger items (Sprint 11) |
| `disassem.impure.lisp` | reported | 1 | debugger | frame walking: `backtrace`, `sb-di` frames, `restart-frame`, `return-from-frame`, stepping (breakpoints by code patching are impossible here, `debug.impure` dies of `lose`): `:broken-on :wasm` with the issue "debug-int on the wasm control stack" (Sprint 11) |
| `disassem.pure-cload.lisp` | reported | 1 | debugger | frame walking: `backtrace`, `sb-di` frames, `restart-frame`, `return-from-frame`, stepping (breakpoints by code patching are impossible here, `debug.impure` dies of `lose`): `:broken-on :wasm` with the issue "debug-int on the wasm control stack" (Sprint 11) |
| `dynamic-extent.pure.lisp` | reported | 52 | backend | `dynamic-extent` is not honoured (no stack allocation in the backend; Sprint 4 carry-over): `:broken-on :wasm` for the no-consing and `stack-allocated-p` checks (issue "dx allocation") |
| `exhaust.impure.lisp` | reported | 0 | runtime | the host no longer aborts: "call stack exhausted" is a trap; `storage-condition` needs a control-stack guard: the file is skipped (depth) until then |
| `external-format.pure.lisp` | trap: indirect call type mismatch | 0 | runtime | after the fix: `:end-of-file` ("select(2) failed on fd 6": no `poll`/`select` on a file under WASI), `:attempt-resync` (no-signals, tagged), `:invalid-external-format` (`run-program :input :stream`, no-fork) |
| `fifo-slow.impure.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `filesys.pure.lisp` | trap: indirect call type mismatch | 0 | environment | after the fix: `(file-author stringp)` expects a user name and there is no user database: `:skipped-on :wasm` (no-passwd) |
| `filesys.test.sh` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `finalize.impure.lisp` | reported | 1 | runtime | collector: code iteration count, `page-protected-p` (no mprotect: skip, no-mprotect), read-only space strings; weak hash tables not culled; finalizers not all run: to look at |
| `float-2.pure.lisp` | reported | 5 | lisp | to look at individually (first failure in the log) |
| `float.pure.lisp` | trap: indirect call type mismatch | 0 | no-float-traps | `:no-float-traps` is on the features for this target now (`test-funs.lisp`), which turns the overflow tests into expected failures |
| `foreign-stack-alignment.impure.lisp` | reported | 0 | environment | a C compiler, shared objects, the host's `make`, the crossbuild manifest, or `local-target-features` of the host build: `:skipped-on :wasm` (no-cc / environment) |
| `foreign.test.sh` | reported | 0 | environment | a C compiler, shared objects, the host's `make`, the crossbuild manifest, or `local-target-features` of the host build: `:skipped-on :wasm` (no-cc / environment) |
| `gc-slow.impure.lisp` | reported | 0 | runtime | heap: "Signalling HEAP-EXHAUSTED in a WITHOUT-INTERRUPTS" (512 MiB default; the test allocates past it under `without-interrupts`): to look at with the collector items |
| `gc.impure.lisp` | reported | 3 | runtime | collector: code iteration count, `page-protected-p` (no mprotect: skip, no-mprotect), read-only space strings; weak hash tables not culled; finalizers not all run: to look at |
| `genheaders.test.sh` | reported | 0 | environment | a C compiler, shared objects, the host's `make`, the crossbuild manifest, or `local-target-features` of the host build: `:skipped-on :wasm` (no-cc / environment) |
| `hash-2.pure.lisp` | reported | 5 | runtime | collector: code iteration count, `page-protected-p` (no mprotect: skip, no-mprotect), read-only space strings; weak hash tables not culled; finalizers not all run: to look at |
| `hash-cache.pure.lisp` | reported | 1 | unsupported | `setitimer` (no timers, no signals under WASI): `:skipped-on :wasm` (no-signals) for the interrupt-driven tests; a host timer through the pending-interrupt word is Sprint 11 |
| `hash-table.impure.lisp` | reported | 1 | lisp | to look at individually (first failure in the log) |
| `hash.pure.lisp` | trap: unreachable | 0 | foreign | fixed: `murmur3_fmix32` was not in the linkage table (listed now); `:sxhash-on-displaced-string` is `:fails-on :sbcl` |
| `heapsort.pure-cload.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: libc or runtime function absent from the linkage table (`strdup`, `strcat`, `varint_unpack`, `gc_heapsort_uwords`, `hopscotch_*`, `gc_private_*`, `debug_function_name_from_pc` ...): now listed, and an undefined alien signals `undefined-alien-function-error` |
| `hide-packages.test.sh` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `hopscotch.impure-cload.lisp` | reported | 0 | foreign | still "indirect call type mismatch" with `hopscotch_*` in the table: a declaration in the test differs from the C prototype; to look at |
| `init-hooks.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `init.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `interface.impure.lisp` | reported | 0 | debugger | frame walking: `backtrace`, `sb-di` frames, `restart-frame`, `return-from-frame`, stepping (breakpoints by code patching are impossible here, `debug.impure` dies of `lose`): `:broken-on :wasm` with the issue "debug-int on the wasm control stack" (Sprint 11) |
| `interface.pure.lisp` | reported | 1 | environment | a C compiler, shared objects, the host's `make`, the crossbuild manifest, or `local-target-features` of the host build: `:skipped-on :wasm` (no-cc / environment) |
| `load.impure.lisp` | reported | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |
| `lzcore.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `macro-policy-decls.impure-cload.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `mop.impure.lisp` | reported | 1 | backend | `dynamic-extent` is not honoured (no stack allocation in the backend; Sprint 4 carry-over): `:broken-on :wasm` for the no-consing and `stack-allocated-p` checks (issue "dx allocation") |
| `mv-return.impure.lisp` | reported | 1 | unsupported | `setitimer` (no timers, no signals under WASI): `:skipped-on :wasm` (no-signals) for the interrupt-driven tests; a host timer through the pending-interrupt word is Sprint 11 |
| `packages.impure.lisp` | reported | 1 | lisp | to look at individually (first failure in the log) |
| `pathnames.pure.lisp` | trap: indirect call type mismatch | 0 | backend | after the `nanosleep` fix: `:intern-pathname-non-consy` (consing check): `dynamic-extent` not honoured, with `dynamic-extent.pure.lisp` |
| `print.impure.lisp` | reported | 1 | unsupported | `setitimer` (no timers, no signals under WASI): `:skipped-on :wasm` (no-signals) for the interrupt-driven tests; a host timer through the pending-interrupt word is Sprint 11 |
| `private-cons.impure.lisp` | reported | 0 | foreign | fixed: libc or runtime function absent from the linkage table (`strdup`, `strcat`, `varint_unpack`, `gc_heapsort_uwords`, `hopscotch_*`, `gc_private_*`, `debug_function_name_from_pc` ...): now listed, and an undefined alien signals `undefined-alien-function-error` |
| `reader.impure.lisp` | reported | 3 | lisp | to look at individually (first failure in the log) |
| `reader.pure.lisp` | reported | 3 | backend | `dynamic-extent` is not honoured (no stack allocation in the backend; Sprint 4 carry-over): `:broken-on :wasm` for the no-consing and `stack-allocated-p` checks (issue "dx allocation") |
| `relocation.test.sh` | reported | 0 | environment | a C compiler, shared objects, the host's `make`, the crossbuild manifest, or `local-target-features` of the host build: `:skipped-on :wasm` (no-cc / environment) |
| `run-program.impure.lisp` | reported | 3 | unsupported | `run-program` `:wait nil`, `:stream`, process objects with signals: `:skipped-on :wasm` (no-fork) where async; the rest to look at |
| `run-program.test.sh` | reported | 0 | unsupported | `run-program` `:wait nil`, `:stream`, process objects with signals: `:skipped-on :wasm` (no-fork) where async; the rest to look at |
| `run-sbcl.test.sh` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `save1.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `save2.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `save3.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `save4.test.sh` | reported | 0 | runtime | module exhaustion: thousands of run-time modules exhaust the host's executable mappings ("unable to make memory executable"); task 50 |
| `save5.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `save6.test.sh` | reported | 0 | runtime | save: `:executable t` writes a file the host cannot run ("Exec format error"); Sprint 11: a launcher script with the core appended |
| `save7.test.sh` | reported | 0 | runtime | save: `:executable t` writes a file the host cannot run ("Exec format error"); Sprint 11: a launcher script with the core appended |
| `save8.test.sh` | reported | 0 | runtime | save: "exit with invalid exit status outside of [0..126)" at `proc_exit` in the saved core's toplevel; to look at with the save fixes |
| `save9.test.sh` | reported | 0 | runtime | save: `save-lisp-and-die` to another name does not write the core module file (`<name>-core.wasm`); the saved core cannot start |
| `sb-bsd-sockets.impure.lisp` | reported | 0 | unsupported | blocklisted contrib (`sb-posix`, `sb-bsd-sockets`, `sb-gmp`, `sb-mpfr`, `sb-sprof`, `sb-simple-streams`): the test file must not run (`:skipped-on :wasm`, no such contrib) |
| `sb-concurrency.impure.lisp` | reported | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |
| `sb-cover.impure.lisp` | reported | 1 | unsupported | `sb-cover`: code coverage fixups are not supported by the backend yet ("code coverage is not supported on this target yet"): `:skipped-on :wasm` |
| `sb-gmp.impure.lisp` | reported | 0 | unsupported | blocklisted contrib (`sb-posix`, `sb-bsd-sockets`, `sb-gmp`, `sb-mpfr`, `sb-sprof`, `sb-simple-streams`): the test file must not run (`:skipped-on :wasm`, no such contrib) |
| `sb-introspect.impure.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `sb-mpfr.impure.lisp` | reported | 0 | unsupported | blocklisted contrib (`sb-posix`, `sb-bsd-sockets`, `sb-gmp`, `sb-mpfr`, `sb-sprof`, `sb-simple-streams`): the test file must not run (`:skipped-on :wasm`, no such contrib) |
| `sb-posix.impure.lisp` | reported | 0 | unsupported | blocklisted contrib (`sb-posix`, `sb-bsd-sockets`, `sb-gmp`, `sb-mpfr`, `sb-sprof`, `sb-simple-streams`): the test file must not run (`:skipped-on :wasm`, no such contrib) |
| `sb-simple-streams.impure.lisp` | reported | 0 | unsupported | blocklisted contrib (`sb-posix`, `sb-bsd-sockets`, `sb-gmp`, `sb-mpfr`, `sb-sprof`, `sb-simple-streams`): the test file must not run (`:skipped-on :wasm`, no such contrib) |
| `sb-sprof.impure.lisp` | reported | 0 | unsupported | blocklisted contrib (`sb-posix`, `sb-bsd-sockets`, `sb-gmp`, `sb-mpfr`, `sb-sprof`, `sb-simple-streams`): the test file must not run (`:skipped-on :wasm`, no such contrib) |
| `script.test.sh` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `selfbuild-output.pure.lisp` | reported | 1 | environment | a C compiler, shared objects, the host's `make`, the crossbuild manifest, or `local-target-features` of the host build: `:skipped-on :wasm` (no-cc / environment) |
| `seq.impure.lisp` | reported | 0 | runtime | module exhaustion: thousands of run-time modules exhaust the host's executable mappings ("unable to make memory executable"); task 50 |
| `signals.impure.lisp` | reported | 1 | unsupported | `setitimer` (no timers, no signals under WASI): `:skipped-on :wasm` (no-signals) for the interrupt-driven tests; a host timer through the pending-interrupt word is Sprint 11 |
| `sleepytests.pure.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |
| `step.pure.lisp` | reported | 7 | debugger | frame walking: `backtrace`, `sb-di` frames, `restart-frame`, `return-from-frame`, stepping (breakpoints by code patching are impossible here, `debug.impure` dies of `lose`): `:broken-on :wasm` with the issue "debug-int on the wasm control stack" (Sprint 11) |
| `stream.impure.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `stream.pure.lisp` | reported | 3 | lisp | to look at individually (first failure in the log) |
| `stream.test.sh` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `threads-slow.pure.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |
| `threads.impure.lisp` | reported | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |
| `threads.pure.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |
| `timer.impure.lisp` | trap:  | 0 | unsupported | `setitimer` (no timers, no signals under WASI): `:skipped-on :wasm` (no-signals) for the interrupt-driven tests; a host timer through the pending-interrupt word is Sprint 11 |
| `tmpfile.pure.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: undefined C function (no `getpwuid`/`gethostname`/`tmpfile` in wasi-libc) was a mistyped import; now a stub in `wasm-wasi-os.c` |
| `unwind-to-frame-and-call.impure.lisp` | reported | 15 | debugger | frame walking: `backtrace`, `sb-di` frames, `restart-frame`, `return-from-frame`, stepping (breakpoints by code patching are impossible here, `debug.impure` dies of `lose`): `:broken-on :wasm` with the issue "debug-int on the wasm control stack" (Sprint 11) |
| `utf-8.impure.lisp` | reported | 0 | lisp | to look at individually (first failure in the log) |
| `wait-for.pure.lisp` | trap: indirect call type mismatch | 0 | foreign | fixed: `sb_nanosleep` declared void (it returned nothing; the typed call refused it) |

## 2. The ANSI suite

192 tests failed and 21 crashed (`tests/ansi-test/results.txt`).

| Group | Tests | Class | Action |
|---|---|---|---|
| upstream's expected failures | 116 of the 192 (`ansi-tests.sh`'s list: `FORMAT.*` directives, `REMOVE*.FOLD.*`, `PRINT.BACKQUOTE.RANDOM.*`, `MAKE-CONDITION.3/4`, ...), plus the conditional groups that apply here: no floating-point traps (`EXP.ERROR.4-7`, `EXPT.ERROR.4-7`, as on arm and riscv), `#+sb-unicode` (`BOTH-CASE-P.2`, `CHAR-UPCASE.2`, `CHAR-DOWNCASE.2`), no `sb-fasteval` (`MAP.48`, `SYMBOL-FUNCTION.ERROR.5`, the `REMOVE-IF*.FOLD` cases) | upstream | the `#+wasm` list joins the arm/riscv groups; `CIS.4` (x86 only) passes here |
| state-dependent failures after thousands of tests: `FORMAT.E.3-26`, `FORMAT.F.1`, `PRINT.*-FLOAT.3/4`, `SET-DIFFERENCE.16-19`, `NSET-DIFFERENCE.16-19`, `SET-EXCLUSIVE-OR.17/18(-A)`, `NSET-EXCLUSIVE-OR.17/18(-A)`, `SET-DIFFERENCE.FOLD.1`, `ROW-MAJOR-AREF.2`, `SET-SYNTAX-FROM-CHAR.SHARP.1/2`, `SYNTAX.SHARP-C.6/7`, `SYNTAX.NUMBER-TOKEN.4`, `PPRINT-TAB.ERROR.5(-UNSAFE)` (55) | runtime | each passes alone in the saved suite core; in the run they fail with "Perfect hash generator failed" or a reader error on the generator's text: the C shadow stack, leaked by every non-local exit through C frames, is spent (`develop.md`, section 7). Fixed by restoring the pointer at the non-local entry; to be confirmed by the rerun |
| `LISTEN.7` | runtime | `listen` on a file stream at its start answers NIL: `sysread-may-block-p` needs `poll`, which WASI lacks (`os-provides-poll` absent); a `select`/`poll_oneoff` path is the fix (next sprint) |
| `FILE-LENGTH.ERROR.3` | environment | `*stderr*` is a file under the test runner (redirected), so `file-length` on it does not signal; passes with a terminal |
| crashed: `SYMBOL-VALUE.ERROR.5`, `MAKUNBOUND.2`, `EVAL.ERROR.4`, `CELL-ERROR-NAME.1`, `ELT-V.10` | backend | the empty-arm `unreachable` (`develop.md`, section 3): fixed |
| crashed: `SLEEP.1/7/8/9` | foreign | `sb_nanosleep` declared with a result it does not have: fixed |
| crashed: `FILE-AUTHOR.1-7`, `MACHINE-INSTANCE.1` | foreign | undefined C functions as mistyped imports: fixed (stubs; `file-author` signals "no match for uid", which the tests record as a failure to look at: a `nil` author would satisfy them) |
| crashed: `INVOKE-DEBUGGER.1`, `INVOKE-DEBUGGER.ERROR.3-5` | unsupported | the process runs with `--disable-debugger`, so invoking the debugger ends it, by design; the driver could run these with the debugger enabled and `*debugger-hook*` bound (next sprint), or they join the expected list |

## 3. After the fixes (the second baseline, `doc/wasm-port/baselines/sprint-9.txt`)

| | first baseline | second baseline |
|---|---|---|
| regression files passed / not passed | 295 / 108 | 343 / 60 |
| files that died of a trap | 37 | 1 (`threads.impure.lisp`, the deadline) |
| test successes reported | 5,520 | 6,958 |
| ANSI pass / fail / crashed | 21,539 / 192 / 21 | 21,543 / 205 / 4 |
| ANSI processes (one per crash) | 48 | 13 |
| ANSI failures outside the expected list | (no list yet) | 62, of which 55 are the state-dependent group |

The 60 files that still fail are the classes the table marks for the
next sprint (debugger, `dynamic-extent`, the collector, executable
cores, timers, the individual items), the files whose remaining
failures are tagged tests that could not be tagged without running
them (now tagged), and the reported failures of `arith-2`, `float-2`
and the "to look at" group.
