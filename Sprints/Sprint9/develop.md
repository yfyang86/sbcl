# Sprint 9 — development notes

Plan: `doc/wasm-port/04-sprints.md`, "Sprint 8: self-hosting and the first
baseline"; test strategy: `doc/wasm-port/05-testing.md`, 5.3.

## 1. Running the runtime the way the scripts expect

The build tree's scripts run `src/runtime/sbcl`; the port's runtime is a
module run under the host. `tools-for-build/wasm-sbcl.sh` is the
executable the scripts can use in its place (it runs
`src/runtime/sbcl.wasm` through `tools-for-build/wasm_run.sh` with the
given SBCL arguments); `run-sbcl.sh`, `tests/subr.sh`
(`SBCL_RUNTIME`), `tests/parallel-exec.sh` and `make-target-contrib.sh`
choose it when `src/runtime/sbcl.wasm` exists and no `src/runtime/sbcl`
does.

1. **The file system.** The host preopened the current directory only,
   so `../output/sbcl.core` from `tests/`, `/tmp` and the tests'
   `TEST_DIRECTORY` were unreachable, and the runtime saw its files under
   `/`. The host now preopens `/` and passes its working directory as
   `PWD`; `os_init` makes it wasi-libc's emulated working directory
   (`chdir`), so relative paths resolve there and absolute host paths
   are the runtime's own. `*runtime-pathname*` comes from `os_preinit`
   (argv[0] made absolute with `PWD`): `runtime.c`'s fallback calls
   `realpath`, which wasi-libc does not provide, and with the directory
   change it yielded NULL, so the cold core died in `native-pathname`
   before internal errors were enabled ("internal error too early in
   init", found with `SBCL_WASM_TRACE_ENTRIES=1`).

## 2. `run-program` through the host

The regression runner runs every impure test file in a child SBCL and
every shell test in `/bin/sh`, through `sb-ext:run-program`; WASI cannot
create processes, the host can (5.3). `sbcl_host.run_process(spec,
length)` runs a child on the host and waits for it: the spec is
NUL-separated fields (argc, argv, directory, then a mode and a path for
each of stdin, stdout and stderr, then the environment), the child's
stdio is null, inherited from the host, or a file, a program ending in
`.wasm` is run under the host itself (so `(run-program
*runtime-pathname* ...)` starts another SBCL), and the result is the
exit code, 128 + signal, or -1. The runtime imports it as
`wasm_run_process` (in the linkage table).

`#+wasm run-program` (`src/code/run-program.lisp`, the original
definition is `#-wasm`) builds on it: `:wait` must be true, `:pty` and
`:stream` are unsupported; an input stream is copied to a temporary
file before the child starts and an output or error stream receives
the child's file afterwards; the environment is always passed
explicitly, from wasi-libc's `environ` (so `setenv` from Lisp, which
`test-util` uses for `SBCL_SOFTWARE_TYPE`, reaches the child), which
put `environ` in the linkage table as a variable
(`wasm-linkage-extra.txt` now takes `name data`). The process object is
returned already `:exited`.

2. **What it runs.** `/bin/echo` and `/bin/sh -c` with inherited,
   captured and merged output, a stream as input, exit codes, and a
   child runtime: `deftype.impure.lisp` passes under `run-tests.sh`
   with its child through the host.
3. **The runner's invariants.** The pure runner compares the values of
   every system symbol before and after a file; on this target every
   compilation pushes a module on `*wasm-loaded-modules*` and advances
   `*wasm-table-next*`, so they (and the disassembler's parsed core
   module) are on `*ignore-symbol-value-change*`.
4. **Parallel execution.** `parallel-exec.lisp` forks and execs; the
   port's `tests/wasm-parallel-exec.sh` runs one `run-tests.sh FILE`
   per test file, N at a time on the host, and summarizes the logs
   (`parallel-exec.sh` hands over to it).

## 3. `disassemble`

A function's code is not in its code object: the simple-fun's self slot
is the table index of its Wasm function, in the core module or in a
module compiled at run time. `src/compiler/wasm/target-insts.lisp`
reads the module (the file next to the core, or the entry of
`*wasm-loaded-modules*` whose range holds the index), parses its
sections (imports, code, `sbcl.core.table`, names) and decodes the
body with an opcode table covering the instructions the backend emits
(control, `try_table`, calls, locals and globals, loads and stores,
constants, numeric, the `0xFC` prefix, references); each line shows the
offset in the body and in the module, the latter being what the host's
trap backtraces report. `disassemble-fun` and
`disassemble-code-component` hand over to it `#+wasm`.

## 4. Features

`:wasm32` and `:wasi` join `:wasm` in the target features
(`crossbuild-runner/backends/wasm/features`), as 5.2 promises the tests.
