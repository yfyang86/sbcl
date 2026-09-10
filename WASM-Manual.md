# SBCL on WebAssembly — build and user manual

This manual covers the WebAssembly port of SBCL that lives on the
`wasm-dev` branch: what it is, what it can do today, how to set up the
tool chain on Linux and macOS, how to build and run it, and how to debug
it. The design and the sprint plan are in `doc/wasm-port/`; each sprint's
records (development notes, UAT script and result, findings) are in
`Sprints/SprintN/`.

## 1. What it is

The port compiles Lisp to WebAssembly with a new compiler backend
(`src/compiler/wasm/`), builds the cold core with the usual cross-build
(`crossbuild-runner`, target `wasm`), and runs the C runtime
(`src/runtime`) compiled for `wasm32-wasip1` under a Wasmtime host written
in Rust (`wasm/crates/sbcl-wasm-host`). The pieces:

| Piece | Where | Product |
|---|---|---|
| compiler backend (VOPs, Wasm instruction encoder, function assembler, module writer) | `src/compiler/wasm/`, `src/assembly/wasm/` | fasls carrying Wasm functions |
| genesis for wasm (core module, table indices, foreign symbol list, map) | `src/compiler/generic/genesis.lisp` (`#+wasm` parts) | `obj/xbuild/wasm.core`, `obj/xbuild/wasm-core.wasm`, `wasm-core.wasm.symbols`, `wasm.map`, genesis headers |
| runtime (C, wasi-sdk) | `src/runtime/wasm-*.c`, `wasi-mman.c`, `Config.wasm-wasi` | `src/runtime/sbcl.wasm` |
| host (Rust, Wasmtime) | `wasm/crates/sbcl-wasm-host` | `wasm/target/release/sbcl-wasm` |
| browser host (JavaScript, V8) | `wasm/web/` (Web Worker, WASI shim, `sbcl_host`, REPL page) | served by `wasm/web/serve.mjs` |
| tests | `tests/wasm/` (level 0: assembler/module writer; level 1: differential suite against the host compiler; `tests/wasm/web/`: the browser host under Playwright) and each sprint's `uat.sh` | |

Status after Sprint 6 (`Sprints/Sprint6/`): `sbcl.wasm --version` and
`--help` work; the cold core loads, its core module instantiates and
`!COLD-INIT` runs through stream and signal-function initialization
before stopping in the printer initialization. There is no REPL yet.
The next sprints (plan `doc/wasm-port/04-sprints.md`) bring up the Lisp
side of errors, the debugger and streams.

## 2. Requirements

Pinned tool versions (`tools-for-build/wasm-env.sh`):

| Tool | Version | Used for |
|---|---|---|
| wasi-sdk | 27 | compiling the runtime and test C programs to `wasm32-wasip1` |
| wasmtime | 45.0.0 | running level-0/level-1 tests from the command line (the host embeds the same crate) |
| wasm-tools | 1.240.0 | validating and printing modules |
| binaryen (optional) | 123 | `wasm-opt` on the core module (the `opt` step) |
| host SBCL | 2.4.8 (any recent SBCL works) | running the cross-compiler and genesis |
| Rust (cargo) | stable | building the host |
| Node.js (optional) | 22 | the V8 loader check in the Sprint 5 UAT |

Disk: about 2 GB for the build products (the core module is 40 MB, the
Wasmtime cache entry for it 82 MB). Memory: pass-2 of the cross build
uses about 2 GB.

### 2.1 Linux (x86-64)

The layout Sprint 1 set up, also the default of the wrapper script:

```
wasi-sdk     /home/user/tools/wasi-sdk    (or $HOME/tools/wasi-sdk, /opt/wasi-sdk)
wasmtime     in PATH                      (or $HOME/.wasmtime/bin)
wasm-tools   in PATH                      (or $HOME/.cargo/bin)
sbcl         in PATH
cargo        in PATH (rustup)
```

`./build-wasm-linux-x86_64.sh toolchain` checks these and downloads what
is missing: wasi-sdk into `$HOME/tools`, wasmtime into
`$HOME/.wasmtime/bin`, wasm-tools into `$HOME/.cargo/bin`, and a host
SBCL under `$HOME/.local` (then add `$HOME/.local/bin` to `PATH` and set
`SBCL_HOME=$HOME/.local/lib/sbcl`). Rust is not installed automatically:
use `https://rustup.rs`.

### 2.2 macOS (Apple silicon, arm64)

The layout the port is developed against on macOS:

```
WASMTIME_BIN_PATH="$HOME/.wasmtime/bin"
WASISDK_PATH="$HOME/bin/wasi-sdk"
WASMTOOLS_BIN_PATH="$HOME/.cargo/bin"
```

that is

```
$ ls $HOME/.wasmtime
LICENSE   README.md bin
$ ls $HOME/bin/wasi-sdk
VERSION bin     include lib     share
$ which wasm-tools
/Users/user/.cargo/bin/wasm-tools
```

`./build-wasm-darwin-arm64.sh toolchain` uses whatever is already in
those places and downloads the pinned arm64 macOS releases
(`wasi-sdk-27.0-arm64-macos`, `wasmtime-v45.0.0-aarch64-macos`,
`wasm-tools-1.240.0-aarch64-macos`) into them otherwise. The host SBCL is
not downloaded on macOS: `brew install sbcl`. Rust: `https://rustup.rs`.
The macOS wrapper only sets the environment; the build steps are the same
as on Linux. (Note: the Sprint 1–6 records were produced on Linux; the
macOS path has not been exercised by the automated UAT.)

### 2.3 Other systems

Set `WASISDK_PATH`, `WASMTIME_BIN_PATH` and `WASMTOOLS_BIN_PATH` in the
environment and run `./build-wasm.sh`; the toolchain step then only
checks (no release asset names are known for other platforms).

## 3. Building

Everything goes through `build-wasm.sh`; the platform wrappers set the
tool paths and call it:

```
./build-wasm-linux-x86_64.sh          # Linux: toolchain host lisp runtime grovel smoke
./build-wasm-darwin-arm64.sh          # macOS: the same
./build-wasm.sh env                   # show the tool-chain settings
./build-wasm.sh --help
```

Steps, in the order `all` runs them:

| Step | What it does | Time | Products |
|---|---|---|---|
| `toolchain` | checks wasi-sdk, wasmtime, wasm-tools, host SBCL, cargo (and binaryen, optional); downloads missing pinned releases (`--no-download` to only check) | seconds | |
| `host` | `cargo build --release -p sbcl-wasm-host` | 1–3 min first time | `wasm/target/release/sbcl-wasm` |
| `grovel` | compiles `tools-for-build/grovel-headers.c` for wasm32-wasi and runs it under the host to check or regenerate the target's C constants (`crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp`); needs the genesis headers, so it runs after `lisp` (as upstream's make-target-1 does); if the constants changed it says so and the Lisp side must be rebuilt | seconds | the groveled file |
| `lisp` | writes `version.lisp-expr` if missing (a generated file the cross-compiler reads; `generate-version.sh` when the clone has the `sbcl-*` tags, else the base release plus the commit), then crossbuild pass-1 (the cross-compiler in the host SBCL) then pass-2 (cross-compiles the tree, runs genesis) | 4 + 15 min | `obj/xbuild/wasm/xc.core`, `obj/xbuild/wasm.core`, `obj/xbuild/wasm-core.wasm`, `wasm-core.wasm.symbols`, `wasm.map`, `obj/xbuild/wasm/genesis-headers/` |
| `opt` | (not in `all`) binaryen's `wasm-opt -O2 -g` on `obj/xbuild/wasm-core.wasm`, the original kept as `wasm-core.wasm.orig`; run it before `warm` so that the saved cores carry the optimized module (12% smaller; Wasmtime compiles the changed module once, then caches it). The CI job runs it. | 30 s | the optimized `obj/xbuild/wasm-core.wasm` |
| `runtime` | `tools-for-build/wasm-build-runtime.sh`: genesis headers into `src/runtime/genesis/`, target symlinks, generated linkage table, `make sbcl.wasm` with wasi-sdk | 1 min | `src/runtime/sbcl.wasm` |
| `smoke` | `sbcl.wasm --version` and `--help` under the host | seconds | |
| `test` | level-0 suite; rebuilds the after-xc core and runs the level-1 differential suite | 12 min | logs in `obj/wasm-build/` |
| `run` | runs `sbcl.wasm --core obj/xbuild/wasm.core`, arguments after `--` go to the runtime | | |
| `clean` | removes the Lisp products and runtime objects | | |

`--fast` skips pass-1, pass-2 and the after-xc build when their products
exist (use it after a change to the runtime or the host). `--jobs N` sets
the runtime build's parallelism. Logs of every step are in
`obj/wasm-build/*.log`.

Typical loops:

```
# C runtime or host change
./build-wasm.sh --fast runtime smoke

# compiler backend change (anything under src/compiler/wasm or genesis)
./build-wasm.sh lisp runtime smoke

# target Lisp change only (src/code, src/pcl, ...): pass-2 without pass-1.
# --fast skips pass-2 while obj/xbuild/wasm.core exists, so remove it first
rm -f obj/xbuild/wasm.core && ./build-wasm.sh --fast lisp runtime smoke

# run the cold core with the call trace and a 60 s deadline
SBCL_WASM_TRACE_CALLS=1 SBCL_WASM_TIMEOUT=60 ./build-wasm.sh run -- --noinform
```

The sprint scripts are still there for the record: `Sprints/Sprint5/pass1.sh`,
`pass2.sh`, `after-xc.sh`, `Sprints/Sprint6/genesis-map.sh` (genesis alone,
three minutes, when only genesis changed) and each sprint's `uat.sh`.

## 4. Running

`tools-for-build/wasm_run.sh MODULE.wasm [args]` runs any WASI module under
the host (building the host on first use). The runtime:

```
tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --version
tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --help
tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform
```

The cold core reaches the REPL: `--eval`, `--load`, `--non-interactive`
and the other runtime and toplevel options work as on any SBCL, the REPL
reads standard input, and errors enter the condition system (the
debugger prints a backtrace; `--disable-debugger` is implied by
`--non-interactive`). The first run compiles the core module (about
30 s), later runs start in about 2.5 s from Wasmtime's cache:

```
tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core obj/xbuild/wasm.core \
    --noinform --non-interactive --eval '(print (+ 1 2))'
```

Paths are relative to the current directory, which the host preopens for
WASI. The core module (`<core minus .core>-core.wasm`) must sit next to
the core file; the runtime asks the host to instantiate it.

Environment variables read by the host and the runtime:

| Variable | Effect |
|---|---|
| `SBCL_WASM_VERBOSE=1` | print the core module's compile and instantiate times |
| `SBCL_WASM_TIMEOUT=<s>` | terminate the run after that many seconds with a Wasm backtrace and the Lisp register file |
| `SBCL_WASM_TRACE_CALLS=1` | print every `call_into_lisp` (function, table index, argument count) |
| `SBCL_WASM_TRACE_ENTRIES=1` | print every Lisp function entry (the callee's name or table index, NARGS, CFP, CSP, OCFP, A0, A1, as the register area has them at the entry's safe point); decode with `tools-for-build/wasm-coreindex.py --annotate` |
| `SBCL_WASM_TRACE_ALLOC=1` | print the frame registers at every allocation |
| `SBCL_WASM_VERIFY_GC=1` | run the collector's heap verifier before and after every collection; it reports each pointer to a stale object (`Ptr ... sees ...`) and code objects written without the "written" flag |
| `SBCL_WASM_TRACE_AFTER_GC=1` | switch the entry trace on at the end of the first collection (the trace from startup is too long to be useful) |
| `SBCL_WASM_CHECK_STACK=1` | watch the bottom 2 KiB of the control stack (the toplevel frames) at allocation slow paths, safe points, module instantiations, runtime-to-Lisp calls and internal errors, and report the first time live words there turn to zero |
| `SBCL_WASM_CHECK_FDEFNS=N` | after the core is loaded, report every fdefn raw-addr, simple-fun self slot and alien linkage cell at or above table index N (for a saved core whose calls trap out of bounds) |
| `SBCL_WASM_DUMP_MODULE=N` | write the saved run-time module whose table range starts at or below N to `obj/wasm-build/module-BASE.wasm`, for `tools-for-build/wasm-func.py --module` |
| `SBCL_WASM_DUMP_INSTALLED=1` | write every module installed at run time (`compile`, `load`) to `obj/wasm-build/installed-BASE.wasm` |
| `SBCL_WASM_WARM_HEAP=SIZE` | the dynamic space of the two warm-load phases (`tools-for-build/wasm-warm.sh`; default `1536MB`, the 512 MiB default fills up during the PCL compile) |
| `SBCL_WASM_TRACE_ERRORS=1` | print every internal error the runtime hands to Lisp (trap kind, error code, argument descriptors, registers, the fdefn in LEXENV) |
| `SBCL_WASM_HOST=<path>` | the host binary `wasm_run.sh` uses |
| `WASMTIME_BACKTRACE_DETAILS=1` | Wasmtime's own richer backtraces |

Ctrl-C: the first press sets the interrupt-pending word of the Lisp
register file (not yet serviced by Lisp code); the second terminates the
run with a backtrace. Compiled modules are cached in Wasmtime's default
cache directory (`~/.cache/wasmtime` on Linux, `~/Library/Caches/...` on
macOS), so the core module compiles once (24 s) and loads in under a
second afterwards.

### 4.1 Loading ASDF systems

ASDF ships as a contrib and loads with `(require :asdf)` (`SBCL_HOME`
must point at `obj/sbcl-home` — `wasm_run.sh` does not set it, export
it beside the command). Third-party systems load the usual way:

```
export SBCL_HOME=$PWD/obj/sbcl-home
tools-for-build/wasm_run.sh src/runtime/sbcl.wasm --core output/sbcl.core \
    --noinform --no-sysinit --no-userinit \
    --eval '(require :asdf)' \
    --eval '(push #P"/path/to/system/" asdf:*central-registry*)' \
    --eval '(asdf:load-system :system-name)'
```

`compile-file` and `load` of the system's files work (each compiles to
a per-component Wasm module, installed through the host as `compile`
does); ASDF's output translations cache the fasls under
`~/.cache/common-lisp/sbcl-2.4.8-wasm-linux-wasm32/` keyed by the
source path.

An example is `example/cl-plot-master/` (a Common Lisp interface to
gnuplot that targets ECL): `load-on-sbcl.lisp` loads it on the port —
`ext-compat.lisp` supplies the ECL-only `EXT:SHELL` and `EXT:CD` on
SBCL first. Loading, CLOS and file writing all work under the port;
spawning the plot's `bash`/`gnuplot` does not (WASI preview 1 has no
process spawning): `EXT:SHELL` reports that, and the commands are in
the command file the figure wrote (run them outside the sandbox).

### 4.2 The browser host (Sprint 14)

`wasm/web/` runs the same runtime and core under V8 instead of
Wasmtime: a Web Worker (the runtime's Wasm and its synchronous module
compilation belong off the main thread), a WASI preview 1 shim over an
in-memory file system (`wasi.js`), the `sbcl_host` contract
(`sbcl-host.js`, SBCL-Handoff.md section 4), and a REPL page
(`index.html`, `repl.js`). A dev server ties it together:

```
node wasm/web/serve.mjs            # http://127.0.0.1:8625/
```

and serves the page, the worker and the build products
(`src/runtime/sbcl.wasm`, `output/sbcl.core`, `output/sbcl-core.wasm`),
with the COOP/COEP headers that make the page crossOriginIsolated —
the worker's thread is inside Wasm while Lisp runs and cannot service
`postMessage`, so the page writes standard input into a
SharedArrayBuffer ring (`ring.js`) and notifies it. Without the
headers (or outside a worker), input falls back to a non-blocking
queue and the REPL sees it at the next poll.

What works there: the whole language through the same core the
Wasmtime host runs, `compile` and `compile-file`/`load` at run time
(each module instantiated synchronously in the worker), timers
(delivered at the WASI clock reads, as the handoff's 4.5 says — a
tick waits for the next `clock_time_get`), Ctrl-C (bit 1 of the
interrupt-pending word, same point). What does not: `run-program`
(`sbcl_host.run_process` answers -1), the `save-lisp-and-die` file
writes land in the in-memory file system and are lost, and no
`js_call` from Lisp yet (`contrib/sb-js/` is the skeleton).

A Node driver runs the same host code without a browser
(`node --experimental-wasm-exnref wasm/web/node-smoke.mjs
output/sbcl.core output/sbcl-core.wasm [stdin.lisp]`; Node 22 needs
`--experimental-wasm-exnref`, Node 24 and current browsers have the
exception proposal on). The Playwright suite is
`tests/wasm/web/` (`repl.spec.mjs`: boot, REPL round trip, a
`compile`, a subset of pure tests in the worker; Chromium and Firefox,
`PLAYWRIGHT_FIREFOX=1`).

## 5. Tests

- Level 0 (`tests/wasm/run-level0.sh`): the Wasm assembler and module
  writer in the cross-compiler image; modules validated with wasm-tools
  and executed under the wasmtime CLI.
- Level 1 (`XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh`):
  163 differential cases (444 argument sets) compiled by the wasm backend
  and run by the Rust rig (`wasm/crates/sbcl-wasm-test`) against the host
  SBCL's results. Needs the after-xc core (`tests/wasm/make-after-xc.lisp`).
- Sprint UATs (`Sprints/SprintN/uat.sh`): the acceptance checks of each
  sprint; `UAT_FAST=1` skips the Lisp rebuilds. `Sprints/Sprint7/uat.sh`
  is the current full check (the cold core to the REPL, errors, the
  regressions; about 35 minutes).

`./build-wasm.sh test` runs level 0 and level 1.

- cl-bench (`tests/wasm/bench/cl-bench-compare.sh A B SCALE [NAME...]`):
  runs the cl-bench kernels of `tests/wasm/bench/cl-bench-driver.lisp`
  under the port on two cores, or on a core and the host SBCL (`host`),
  at a scale (1 = the original iteration counts), and prints the ratio
  per benchmark and the geometric mean; a `.results` file from an
  earlier run stands in for either side. `CL_BENCH_HEAP` sets the
  dynamic-space size of the port's runs (default `1GB`: the collector
  triggers only at safe points, and the string benchmarks ask for tens
  of megabytes between two), `CL_BENCH_TIMEOUT` bounds one benchmark
  (seconds). Results and logs under `obj/wasm-build/cl-bench/`.

- The saved core (`output/sbcl.core`, from `./build-wasm.sh warm`) is
  what the build tree's scripts run: `run-sbcl.sh`, `tests/subr.sh`
  (so every `tests/*.test.sh`), `tests/parallel-exec.sh` and
  `make-target-contrib.sh` run the runtime through
  `tools-for-build/wasm-sbcl.sh`, the port's "sbcl binary" (the module
  under the host, with the given arguments). The host makes the whole
  file system visible with its own paths and the runtime works in the
  host's directory, and `sb-ext:run-program` runs children on the host
  (`sbcl_host.run_process`: synchronous, stdio as files or inherited;
  a `.wasm` program runs under the host), which is how the impure and
  shell tests get their child SBCL. The runtime's `getpid` is the
  host's process id (`sbcl_host.process_id`; WASI has none), so
  concurrent runtimes name their scratch files apart.
- The regression suite: `tests/run-tests.sh [files]` as on any target,
  or all files in parallel with `tests/wasm-parallel-exec.sh [-j N]`
  (`./build-wasm.sh regress`), which logs each file separately and
  summarizes; `Sprints/Sprint9/baseline.sh REGRESS-LOG` writes the
  baseline report (`doc/wasm-port/baselines/`). `SBCL_WASM_TEST_TIMEOUT`
  (seconds, default 1800) bounds each file.
- Tests the port cannot run carry `:skipped-on :wasm` with the reason
  in a comment (`doc/wasm-port/05-testing.md`, 5.2: `no-signals`,
  `no-breakpoints`, `no-fork`, `no-dlopen`, `depth`, ...), whole files
  `(invoke-restart 'run-tests::skip-file)` under `#+wasm`, and the shell
  tests that cannot run exit early when `subr.sh` has set `SBCL_WASM`.
  `:no-float-traps` is on `*features*` while a test file runs.
- The kernel's mapping limit: every component compiled at run time is a
  module of its own, about four memory mappings in the host (a saved
  core starts with one module holding all of them, see below); a file
  that compiles more than about 8,000 components
  (`arith-slow.pure.lisp`, `cmp-combinations.pure.lisp`,
  `seq.impure.lisp`) exhausts the default `vm.max_map_count` of 65,530
  ("unable to make memory executable"). Raise it for the suites
  (`sysctl -w vm.max_map_count=1048576`).
- The ANSI suite: `tests/ansi-tests.sh` (`./build-wasm.sh ansi`; the
  script checks out `tests/ansi-test`) hands over to
  `tests/wasm-ansi-tests.sh`: the suite is loaded once into a saved
  core (`tests/ansi-test/wasm-ansi.core`) and the tests run one at a
  time (`tests/wasm-ansi-driver.lisp`), each result written to
  `tests/ansi-test/results.txt` (`NAME PASS|FAIL|CRASHED`) before the
  next starts, so a trap in one test ends the process, not the run: the
  script restarts it and it resumes from the next test (a test that
  crashed is retried once, then recorded as `CRASHED`). Output in
  `tests/ansi-test/wasm-ansi.log`; the summary at the end;
  `SBCL_WASM_ANSI_TIMEOUT` (seconds, default 1800) bounds one process.
  At the end the results are compared with the expected-failure list of
  `ansi-tests.sh` (the one list; its `#+wasm` entries are the port's),
  and the script exits 1 on an unexpected failure.
  `Sprints/Sprint9/baseline.sh REGRESS-LOG [ANSI-RESULTS]` adds its
  results to the baseline report.
- The contribs: `./build-wasm.sh contrib` builds the pure-Lisp ones into
  `obj/sbcl-home/contrib` (the blocklist is in `build-wasm.sh`);
  `(require :sb-md5)` and the others work in the saved core.
- `save-lisp-and-die` writes the core module beside the core under the
  core's name (`foo.core`, `foo-core.wasm`), and lowers every function
  compiled or loaded at run time into one module saved in the core
  (`*wasm-loaded-modules*`), which the core instantiates when it starts.
  `:executable t` writes a launcher: a `#!/bin/sh` script that runs the
  host and the module that saved it (`SBCL_WASM_HOST`,
  `SBCL_WASM_RUNTIME`, which the host exports to the guest; set them to
  relocate), followed by the core; `*posix-argv*` names the launcher.
  WASI cannot `chmod`, so the launcher needs `chmod +x` before it runs.
- Stack exhaustion signals `storage-condition` as elsewhere: there are
  no guard pages, the compiled code compares the stack pointers with
  limits in the register area at every frame allocation and binding
  (`check_stack_guards`, wasm-arch.c). The Wasm stack of the host is
  128 MB; a control stack (`--control-stack-size`) beyond about 30 MB
  would exhaust it first, with an uncatchable trap.
- Timers (`sb-ext:make-timer`, `with-timeout`, deadlines) work: the
  runtime keeps the `setitimer` deadline and the host ticks the epoch
  when it is due (`sbcl_host.set_timer`), setting the timer bit of the
  interrupt-pending word; the next safe point runs the expired timers
  (deferred under `without-interrupts`), and a sleep is cut at the
  deadline. Nothing interrupts a call the host blocks in (`run-program`
  waiting for its child).
- A call to an alien function the runtime does not define signals
  `undefined-alien-function-error` with the name, whatever the declared
  signature (the linkage table maps such names to a guard the compiled
  call checks for).
- `disassemble` prints a function's Wasm instructions (body and module
  offsets, the latter what a trap backtrace reports);
  `(sb-wasm-asm::disassemble-table-index N)` does the same for a table
  index.

## 6. Debugging

- **Backtraces.** Every trap (a Lisp internal error ends in an
  `unreachable`, out-of-bounds accesses, the deadline) prints a Wasm
  backtrace with function names: runtime C functions by name, core module
  functions as their entry name (an XEP) or `lambdaN` (a body), plus the
  Lisp register file. Frames replaced by tail calls are not shown.
- **`tools-for-build/wasm-coreindex.py`** maps a backtrace offset
  (`off:HEX`), a module function index (`func:N`), a table index
  (`table:N`) or a heap address (`addr:HEX`) to the Lisp function, using
  `obj/xbuild/wasm.map` (every fdefn's function address and name, written
  by genesis) and the core's simple-fun self slots; `header:HEX` lists the
  boxed constants of the code object holding a function, by name;
  `--annotate` decodes the table indices in a trace or backtrace read
  from stdin.
- **`tools-for-build/wasm-func.py off:HEX`** prints the function containing
  a code offset as text with binary offsets and marks the instruction.
- **The register file**: compiled code keeps the Lisp registers it uses
  in Wasm locals (`reg.get`, `reg.set` in `insts.lisp`) and writes them
  to the register area of the thread structure before every call,
  return, throw and runtime entry (a `:flush` note the function
  assembler lowers), reading them back after a call and at every entry;
  so between those points the area is stale, and a dump of it (the trap
  register file, the entry trace) shows a register as of the last flush.
  NARGS and A0..A3 are the parameters of the Lisp function type,
  `(i32 i32 i32 i32 i32) -> (i32)`, the result the values flag; a
  callee reads them from its parameters, not the area, and every Lisp
  function flushes and reloads them like registers it uses. The float
  registers stay in the area.
- **The entry trace** (`SBCL_WASM_TRACE_ENTRIES=1`): every XEP is a safe
  point that calls the runtime when the register area's interrupt-pending
  word is set, and so is every backward branch between blocks (a loop's
  back edge); the runtime prints each such point when the word is 2 (an
  "enter" line per loop iteration as well). Local functions (no XEP)
  appear only through their loops; tail calls replace frames.
- **Internal errors** enter the Lisp condition system (`internal-error`
  with a context that snapshots the register file). Before
  `internal_errors_enabled` is set by cold-init, or if the handler
  returns, the runtime prints the trap kind, error code, argument
  descriptors, all registers and, for a named call, the callee's fdefn
  name, then stops; `SBCL_WASM_TRACE_ERRORS=1` prints the same report
  for every error. Every trap report from the host also dumps the first
  words of the frames at OCFP and CFP.
- **Stray writes.** `SBCL_WASM_CANARY=1` places 4 MB canary regions
  before and after the thread block and checks them, and the null page
  (0..0x3ff), after every collection (`wasm_check_canaries`, callable
  from Lisp too); `SBCL_WASM_WATCH=HEXADDR` reports the runtime entry
  point (internal error, safe point, `call_into_lisp`, instantiate) at
  which the word at that address changes, with the frame registers.
- **Foreign calls** trap with "indirect call type mismatch" when the
  Lisp declaration's signature differs from the C function's (`void`
  versus a returned pointer, 32 versus 64-bit integers): check the
  declaration against the C prototype; the groveled types come from
  `./build-wasm.sh grovel`.
- Register file layout: `src/runtime/wasm-lispregs.h` (NARGS, CSP, CFP,
  OCFP, NFP, NSP, LEXENV, CODE, LIP, CFUNC, A0–A3, L0–L5, NL0–NL7, TMP,
  RA; then floats, error arguments, unwind target, float modes, the
  interrupt-pending word, the card table, the last foreign cell, the
  stack limits).

## 7. Source map

```
build-wasm.sh, build-wasm-<system>-<arch>.sh   build driver and platform wrappers
tools-for-build/wasm-env.sh                    tool-chain environment (sourced)
tools-for-build/wasm-build-runtime.sh          build src/runtime/sbcl.wasm
tools-for-build/wasm-linkage-table.sh          generate the runtime's linkage table
tools-for-build/wasm_run.sh                    run a module under the host
src/compiler/wasm/                             backend: parms, vm, insts (encoder), module (writer),
                                               func-asm (function assembler: arms, the dispatch loop,
                                               the register cache's flush and reload),
                                               stackify (structured control flow, the default encoding),
                                               target-insts (the disassembler), VOP files
tests/wasm/bench/                              cl-bench under the port: the driver and the two-core comparison
src/assembly/wasm/                             assembly routines (throw, unwind, trampolines)
src/compiler/generic/genesis.lisp              #+wasm: core module, table indices, map
src/compiler/dump.lisp, src/code/load.lisp     fop-wasm-code (Wasm blobs in fasls)
src/runtime/Config.wasm-wasi                   runtime configuration
src/runtime/wasm-arch.c                        register file, call_into_lisp, internal_error, module loading
src/runtime/wasm-wasi-os.c, wasi-mman.c        OS layer, memory
src/runtime/wasm-interrupt.c                   stubs for the signal interface
src/runtime/wasm-lispregs.h                    register file layout
wasm/crates/sbcl-wasm-host                     the host (sbcl-wasm)
wasm/crates/sbcl-wasm-test                     the level-1 rig and the core loader
tests/wasm/                                    level-0/level-1 suites, mini-runtime, spin.c
crossbuild-runner/backends/wasm/               target features, groveled constants
doc/wasm-port/                                 plan: overview, design, tool chain, sprints, tests
Sprints/SprintN/                               per-sprint records and UATs
```

## 8. Troubleshooting

- *`wasi-sdk not found`*: set `WASISDK_PATH` (or `WASI_SDK`) or run the
  toolchain step.
- *pass-1 stops loading `src/cold/defun-load-or-cload-xcompiler.lisp`
  with `version.lisp-expr does not exist`*: the file is generated, not in
  git; the `lisp` step writes it (older scripts did not). To do it by
  hand: `./generate-version.sh`, or
  `echo '"2.6.8.wasm-dev"' > version.lisp-expr`.
- *`grovel` fails with `use of undeclared identifier 'FIXNUM_TAG_MASK'`*:
  it ran before the `lisp` step; the constants come from the genesis
  headers of pass-2 (`all` orders the steps accordingly).
- *`no genesis headers`*: run the `lisp` step; the runtime needs
  `obj/xbuild/wasm/genesis-headers/` from pass-2 (or `genesis-headers-2`
  from `Sprints/Sprint6/genesis-map.sh`).
- *`no obj/xbuild/wasm-core.wasm.symbols`*: same; the linkage table is
  generated from genesis's symbol list.
- *`unknown import: env::NAME`*: the runtime called a C-library function
  WASI does not provide (`dlopen`, `kill`, `pipe`, ...). These are bound
  to traps on purpose; each becomes an implementation or a Lisp-visible
  error as the OS layer is ported.
- *the core module compiles every time (24 s)*: Wasmtime's cache is
  disabled or its directory is not writable; the host prints
  `no module cache` in that case.
- *`can't open the core module`*: the `-core.wasm` file must be next to
  the `.core`, and the path must be relative to the current directory.
- *pass-2 fails after a backend change*: read `obj/wasm-build/pass-2.log`
  (the failing form is near the end); the after-xc build
  (`tests/wasm/make-after-xc.lisp`) tolerates unimplemented VOPs and
  writes `obj/xbuild/wasm/unimplemented-vops.txt`.
