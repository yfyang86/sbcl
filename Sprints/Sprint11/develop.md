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

(continued below with the finding)

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
pass; `save7.test.sh` reaches its last part (below).
