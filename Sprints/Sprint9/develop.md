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

## 5. The contribs

`./build-wasm.sh contrib` runs `make-target-contrib.sh` with the
runtime wrapper and a blocklist (`SBCL_WASM_CONTRIB_BLOCKLIST`, merged
with `output/build-config`'s, which would otherwise replace it) of the
contribs that need a C compiler, the groveler, threads, sockets or
signals: `sb-posix`, `sb-bsd-sockets`, `sb-sprof`, `sb-capstone`,
`sb-gmp`, `sb-mpfr`, `sb-perf`, `sb-simd`, `sb-grovel`,
`sb-simple-streams`, `sb-manual`. The rest build into
`obj/sbcl-home/contrib`: `asdf` (with `uiop`), `sb-rt`, `sb-md5`,
`sb-cltl2`, `sb-rotate-byte`, `sb-aclrepl`, `sb-executable`, `sb-queue`,
`sb-concurrency`, `sb-introspect`, `sb-cover`; `require` loads each in
the saved core, and `md5sum-string`, `rotate-byte`, `asdf-version` and
`function-lambda-list` answer. (Without the blocklist `sb-posix` and
`sb-gmp` "built" by groveling with the host's C compiler, for Linux.)

## 6. Saving a core from the saved core

`init.test.sh` saves cores; `save-lisp-and-die` from `output/sbcl.core`
died in the save's heap verifier ("sees strange non-pointer", 26 errors
in a simple-vector in read-only space), while `:purify nil` saved and a
verified full collection found nothing.

5. **The purify delimiter's length word.** `prepare_readonly_space`
   writes a length-0 simple-vector header between the symbol names and
   the other data it moves to read-only space (`apropos-list` looks for
   it). On a 64-bit target the length is in the header; on this 32-bit
   one it is the next word, which the first save had left as data and
   the second save read as the length of a vector of garbage headers
   (the boxed single-floats and bignums moved after it). The word is
   now zeroed on 32-bit targets. A core saved from the saved core
   restarts with its variables and CLOS.

## 7. The two suites

The exit criterion is that both suites run to completion; a first run
is meant to be a list of what fails, not a pass.

6. **The regression suite.** `tests/wasm-parallel-exec.sh` runs one
   `run-tests.sh FILE` per test file, N at a time (`-j`, default 3),
   with a deadline per file (`SBCL_WASM_TEST_TIMEOUT`, 1800 s), and
   keeps each file's log; `Sprints/Sprint9/baseline.sh` reads the logs
   into the report: the files that did not pass with the way they ended
   (a reported failure, a trap, a timeout, an exhausted heap, a fatal
   error), then every unexpected failure the runner reported, the
   unexpected successes, the leftover threads and invalid exit
   statuses, and the counts. The first symbol-value check of the pure
   runner (`*wasm-loaded-modules*` and friends) is in section 2.
7. **The ANSI suite: 10,000 instances.** The suite loaded and ran a few
   hundred tests, then the host refused the next instantiation
   ("instance count too high at 10001"): Wasmtime's default store limit
   on instances, and every component compiled at run time is one. The
   host's store now has a limiter with the instance, table and memory
   counts unbounded (`StoreLimitsBuilder`; the memory size stays bounded
   by the module's own maximum).
8. **`getrusage`.** The suite's `TIME` tests died with "getrusage failed:
   Invalid argument": WASI has no process CPU clock and wasi-libc's
   `getrusage` fails. The runtime's `sb_getrusage` on this target
   answers with the monotonic clock since its first call as the user
   time (zero system time), which is what `get-internal-run-time` and
   `time` need; a saved core's clock starts at its first call, not at
   the host's.
9. **One test per process would be too slow; one process per crash is
   not.** A backend trap (`unreachable` in the compiled code of
   `symbol-value.error.5`, then a few more) ends the process, and the
   original `ansi-tests.sh` runs the whole suite in one; every
   restart would repeat the fifteen minutes of loading. So the suite is
   loaded once and saved (`tests/ansi-test/wasm-ansi.core`, with
   `gclload1`, `gclload2` and `tests/wasm-ansi-driver.lisp`), and
   `tests/wasm-ansi-tests.sh` runs `cl-test::wasm-run-tests` in that
   core: the driver writes the name of the test about to run to
   `progress.txt`, runs it with `rt:do-test`, and appends
   `NAME PASS|FAIL` to `results.txt`; when the process dies the script
   starts another, which skips the recorded tests, retries the one
   named in `progress.txt` once (`retry.txt`) and then records it as
   `CRASHED`, and goes on; `progress.txt` reads `DONE` at the end.
   `tests/ansi-tests.sh` hands over to it when `sbcl.wasm` is the
   runtime. The whole run is a few hundred processes at most, each
   restart costing the saved core's startup (about four seconds with
   the suite's modules).
10. **Runtime options after toplevel options are ignored.** The first
    driver died with "Can't find sbcl.core" although it passed `--core`:
    the runtime stops looking for its own options at the first toplevel
    option (`--noinform`, `--no-userinit`, ...), which the script had put
    before `--core`. The scripts keep the runtime options first.
