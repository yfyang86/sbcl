# Sprint 10 — development notes

Plan: `doc/wasm-port/04-sprints.md`, "Sprint 9–10: triage and fix";
conventions: `doc/wasm-port/05-testing.md`, 5.2. The classification of
every baseline failure is `triage.md`; this file records what was
found and fixed, in the order it happened.

## 1. Reading the baseline

The report lists 108 files and 21 crashed ANSI tests. Sorting them by
how the process ended (the trap kind and the last `::: Running` line
in each log, `tools-for-build/wasm-coreindex.py` on the top frame)
gave four classes that killed processes, each with one cause behind
many files: foreign calls (23 files and 3 ANSI tests), `unreachable`
in compiled code (8 files, 5 ANSI tests), module exhaustion (4 files),
and saving a core (12 shell tests).

## 2. Foreign calls

1. **Undefined C functions became mistyped imports.** The linkage table
   (`wasm-linkage-table.c`, generated) declares every name `extern
   void f(void)`; a name that neither the runtime's objects nor
   wasi-libc define (`getpwuid` has no `uid_username` behind it,
   `gethostname`, `tmpfile`, `getuid`, `pipe`, `kill`, ...) is then an
   *import* of type `() -> ()` (the linker's `--allow-undefined`), and
   the Lisp side's typed `call_indirect` refuses it: "indirect call type
   mismatch" in `file-author`, `machine-instance`, `unix-tmpfile`,
   `user-homedir`. The generator now resolves each function against
   the objects and the sysroot's archives (`llvm-nm`) and maps an
   undefined one to the guard `undefined_alien_function`
   (`tools-for-build/wasm-linkage-table.sh`; `WASI_SDK` is exported to
   it).
2. **The guard needs a matching call.** `undefined_alien_function` is
   `void ()`, so calling it with any other signature would trap the
   same way (Sprint 8, item 6). `CALL-OUT` (c-call.lisp) now compares
   the function's table index with the guard's (read from the guard's
   own linkage cell) before the typed call and, when equal, calls the
   guard by its own type; `FOREIGN-SYMBOL-SAP` records the linkage cell
   it read in the thread area (`+thread-foreign-cell-offset+`, 468), from
   which the runtime's `undefined_alien_function` passes the cell to
   `UNDEFINED-ALIEN-FUN-ERROR` (`#+wasm`, interr.lisp), which names the
   function through `alien-linkage-index-to-name`. An undefined alien
   is a Lisp error on this target now, for every signature.
3. **What wasi-libc lacks.** Stubs in `wasm-wasi-os.c`: `uid_username`,
   `uid_homedir`, `user_homedir` answer NULL (no user database; wrap.c's
   versions are `#ifndef LISP_FEATURE_WASM`), `getuid` 0, `gethostname`
   "wasm", `tmpfile` an unlinked file in `/tmp` (no `mkstemp` either).
4. **`sb_nanosleep` returns nothing.** unix.lisp declared it `int`; the
   typed call refused the mismatch (native targets never notice). It is
   `void` now. Nine files died of it (`sleep`, deadlines, `wait-for`,
   the thread tests' timeouts).
5. **Names the tests call.** The linkage table keeps the runtime and
   libc functions the test suite calls through `extern-alien`
   (`strdup`, `strcat`, `bsearch`, `qsort`, `gc_heapsort_uwords`, the
   `hopscotch_*` and `gc_private_*` functions, `varint_unpack`, ...;
   `tools-for-build/wasm-linkage-extra.txt`).

## 3. `unreachable`: an empty arm at a range end

Every `unreachable` trap was in the *test's* compiled code, right after
the `end` of a block: `(let ((s (gensym))) (handler-case (symbol-value
s) ...))` at toplevel reproduced it, `(handler-case (symbol-value
(gensym)) ...)` did not. The function assembler splits a function's
byte ranges into arms at every branch target, and a target at the *end*
of a range gets an empty arm, so that a jump to it can leave for the
function continuing there (`COMPUTE-ARMS`). When the target is also
the start of the function's next range (the first elsewhere chunk
starts exactly where the main range ends), two arms started at the
same position and `ARM-AT` found the empty one: the error branch
dispatched to an arm whose only instruction was the chunk terminator
`unreachable`. `ARM-AT` prefers the arm with code. The eight files
and the five ANSI tests were all error paths for this reason, not
unimplemented VOPs (the build logs report none).

## 4. Saving a core under another name

`save-lisp-and-die "foo.core"` wrote the core but not `foo-core.wasm`,
so every saved core other than the build's (`wasm-warm.sh` copies the
module by hand) failed to start: "can't open the core module"
(`init.test.sh`, `save1..9.test.sh`, `lzcore.test.sh`). `gc_and_save`
now copies the running core's module beside the new core
(`wasm_save_core_module`, wasm-arch.c). `:executable t` remains for the
next sprint (the file is run as a program).

## 5. The host's native stack

`exhaust.impure.lisp` killed the *host*: "thread 'main' has overflowed
its stack". The Wasm call depth lives on the native stack of the thread
running the module; `max_wasm_stack` (64 MB) exceeded the main
thread's 8 MB, so a runaway recursion overflowed the native stack
before Wasmtime's bound. The host now runs the module on a thread with
a 256 MB stack and `max_wasm_stack` at 128 MB, so the bound is a trap.
The Lisp control stack (in linear memory) has no guard yet: a deep
recursion ends in an out-of-bounds memory access at the top of the
memory, not in `storage-condition` (open item).

## 6. Module exhaustion

`arith-slow`, `cmp-combinations`, `seq.impure` and `save4.test.sh` died
in the host's `Module::new`: "unable to make memory executable"
(`mprotect` refused). Counting a process's mappings: the saved core
starts with about 30,000 (7,000 modules, about 4 mappings each: the
compiled code's text and read-only segments), the kernel's default
limit is 65,530 (`vm.max_map_count`), and these files compile more
than 8,000 components. The limit was raised for the baseline runs
(`sysctl vm.max_map_count`, documented in the manual); the fix is to
merge the saved modules into one at save time (Sprint 8, item 7) and
to release the modules of dead code, both for the next sprint.

## 7. The C shadow stack across a non-local exit

The port-specific ANSI failures (58 tests: the `format ~E` family, the
float printers, `set-difference`, the reader tests) all pass one at a
time in the saved suite core, and fail in the run with two symptoms:
"Perfect hash generator failed" (`sb-int:bug`) and "unmatched close
parenthesis" from `read-from-string` on the text the generator
(`lisp_perfhash_with_options`, C) returns. Both mean the C code's
output was corrupt after some twenty thousand tests, thousands of
which signal an error caught by `handler-case`: each such exit unwinds
through the C frames of `wasm_internal_error`, `funcall` and
`call_into_lisp` without their epilogues, so the C shadow stack
pointer (`__stack_pointer`) never comes back (Sprint 8, item 2), and
once the 8 MB shadow stack is spent the generator's stack buffers
overlap other memory. The fix, as designed then: the runtime exports
`c_stack_save` and `c_stack_restore` (`wasm-stack.S`, the global is
only reachable from assembly), `MAKE-UNWIND-BLOCK` and
`MAKE-CATCH-BLOCK` save the pointer in a new slot of the block
(`c-sp`, objdef.lisp, `#+wasm`), and the landing code of a function
with non-local entries (`EMIT-NLX-HANDLER`) restores it through the
runtime's cell before dispatching to the entry.
