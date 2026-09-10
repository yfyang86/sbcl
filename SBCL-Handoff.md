# SBCL on WebAssembly — handoff for the Node.js integration

For the agent embedding this development build of the SBCL WebAssembly
port in a Node.js web application (the way `ecl-wasm` embeds ECL). It
says what the build produces, how the runtime is started today, what a
JavaScript host has to provide, what works and what does not, and how
to check an embedding against the reference host. The full build and
user manual is `WASM-Manual.md`; the design is `doc/wasm-port/`.

Read this file first, then `WASM-Manual.md` sections 4 (running), 5
(tests) and 8 (troubleshooting), then `wasm/crates/sbcl-wasm-host/src/main.rs`
(555 lines, the reference host; its module comment is the contract).

## 1. What exists

The port is at the end of its Sprint 12 (branch `wasm-dev` of
`https://github.com/yfyang86/sbcl`; the sprint records are under
`Sprints/SprintN/`). State:

- A complete SBCL (compiler, `compile-file`, `load`, PCL, the
  condition system, `save-lisp-and-die`, the pure-Lisp contribs
  `asdf sb-rt sb-md5 sb-cltl2 sb-rotate-byte sb-aclrepl sb-executable
  sb-queue sb-concurrency sb-introspect sb-cover`) compiled to
  `wasm32-wasip1`, with structured control flow (Sprint 12's
  stackifier) and the cold core module optimized by binaryen.
- The regression suite and the ANSI suite run under the port: the ANSI
  suite has 0 unexpected failures (21,752 tests, 139 on the expected
  list); the regression suite has a documented list of failing files
  (dynamic-extent allocation, the debugger's frame walking, threads,
  sockets, alien callbacks, some arithmetic corner cases:
  `doc/wasm-port/05-testing.md`, `Sprints/Sprint12/test.md`).
- Performance: 8.2× slower than native SBCL on cl-bench's geometric
  mean (`doc/wasm-port/baselines/sprint-12-cl-bench.md`); startup
  about 1 s under Wasmtime once the module is cached, 24 s the first
  time (the engine compiles the 34 MB module).
- Two hosts exist: `sbcl-wasm`, a Rust program embedding Wasmtime, and
  (Sprint 14) the browser host under `wasm/web/`: a Web Worker, a WASI
  shim and the `sbcl_host` imports in JavaScript, with a REPL page
  (`node wasm/web/serve.mjs`, WASM-Manual.md 4.2). The same host code
  runs in Node (`wasm/web/node-smoke.mjs`) for an in-process embedding
  without the Wasmtime binary; section 4 remains the contract both
  implement.

## 2. The files

A build (`./build-wasm.sh toolchain host lisp opt runtime warm contrib`,
about 35 minutes on 4 cores; `WASM-Manual.md` section 3) produces:

| File | What | Size |
|---|---|---|
| `src/runtime/sbcl.wasm` | the runtime (the C part of SBCL: heap, collector, streams, the loader), a WASI command | 1.4 MB |
| `output/sbcl.core` | the heap image after the warm load | 77 MB |
| `output/sbcl-core.wasm` | the Wasm module holding the compiled Lisp functions of that core (name derived from the core's: `foo.core` → `foo-core.wasm`, must sit next to it) | 34 MB |
| `obj/sbcl-home/contrib/*.fasl` | the contribs, for `(require :name)`; `SBCL_HOME` points at `obj/sbcl-home` | |
| `wasm/target/release/sbcl-wasm` | the reference host (`cargo build --release -p sbcl-wasm-host`) | |

Ship the first three together (and the contribs if the application
uses them). A core saved by `save-lisp-and-die` from the application's
own Lisp state comes with its own `-core.wasm` (the runtime copies the
module next to the new core), so an application can bake its Lisp
code into a core and start from that.

There are no release artifacts: build from the branch, or take the
files from a machine that has. The CI job (`.github/workflows/linux-wasm.yml`)
builds and tests but uploads only logs.

## 3. Running it today: the reference host

```
tools-for-build/wasm-sbcl.sh --core output/sbcl.core --noinform --non-interactive \
    --eval '(print (+ 1 2))'
# or directly
wasm/target/release/sbcl-wasm src/runtime/sbcl.wasm --core output/sbcl.core [sbcl options]
run-sbcl.sh --noinform                # the usual script, routed through the host
```

The command line after the module is SBCL's own (`--core`, `--eval`,
`--load`, `--script`, `--non-interactive`, `--dynamic-space-size`, …).
The REPL reads standard input and writes standard output; errors enter
the debugger unless `--disable-debugger` or `--non-interactive`. The
current directory is preopened for WASI, paths are host paths.

**The quickest working Node integration is this host as a child
process**: `child_process.spawn("sbcl-wasm", ["sbcl.wasm", "--core",
"sbcl.core", "--noinform", "--disable-debugger"])` with a request/reply
protocol over stdio (one form per request, `--eval` per call, or a
long-lived REPL with a sentinel). It is what every test in the tree
does (`tests/subr.sh`, `run-sbcl.sh`), it inherits the host's timers,
`run-program`, Ctrl-C handling and module cache, and it costs no new
code. Its limits: one process per Lisp image, the Wasmtime binary on
the server, no in-process calls between JavaScript and Lisp.

## 4. Running it in-process: what a JavaScript host must provide

The runtime module `src/runtime/sbcl.wasm` imports three namespaces
and exports what the Lisp modules need. Everything below is what
`main.rs` does; do the same in JavaScript.

### 4.1 Engine features

`try_table`/`throw` exception handling (the new exnref proposal),
tail calls (`return_call`, `return_call_indirect`), multi-value, bulk
memory, reference types, sign extension, non-trapping float-to-int.
Node 22 (V8 12.4): tail calls are on by default; exceptions need
`node --experimental-wasm-exnref` (checked in Sprint 1 and 5:
`Sprints/Sprint1/verify.md`, `tests/wasm/load-core.mjs`).

### 4.2 Imports of `sbcl.wasm`

- `wasi_snapshot_preview1`: 24 functions (`args_*`, `environ_*`,
  `clock_time_get`, `fd_close fd_fdstat_get fd_fdstat_set_flags
  fd_filestat_get fd_prestat_get fd_prestat_dir_name fd_read fd_readdir
  fd_seek fd_write`, `path_create_directory path_filestat_get path_open
  path_readlink path_remove_directory path_rename path_unlink_file`,
  `poll_oneoff`, `proc_exit`). Node's built-in `node:wasi`
  (`new WASI({version: "preview1", args, env, preopens, returnOnExit})`,
  `wasi.getImportObject()`, `wasi.start(instance)`) covers them; the
  runtime needs the file system where the core files are, and it
  reads `PWD` from the environment to set its working directory
  (`os_init`), so pass `env: {PWD: process.cwd(), ...}` and preopen
  `/` (or the directories the application allows) as the reference
  host does.
- `sbcl_host` — the port's own contract, four functions:

  | Import | Signature | What it does |
  |---|---|---|
  | `instantiate` | `(bytes: i32, length: i32, register_area: i32, table_base: i32) -> i32` | The runtime read a Lisp module (the core module at startup, then every module `compile`/`load` produce) into its linear memory at `bytes`; the host compiles it, grows the shared function table to `table_base + count` (`count` from the module's `sbcl.core.table` custom section: two little-endian u32, base and count; check base = `table_base`), and instantiates it with the imports of 4.3. Returns 1. Must be synchronous (the runtime continues after the call): `new WebAssembly.Module` + `new WebAssembly.Instance`, not the promise forms. Called once for the 34 MB core module (V8's baseline compiler takes about 0.1 s for it, Sprint 5's measure) and once per compiled Lisp file or top-level `compile` after that. |
  | `set_timer` | `(usec: i64) -> ()` | `sb-ext:make-timer`, `with-timeout`, deadlines: the runtime asks for a tick in `usec` microseconds (0 cancels). The reference host sleeps in a thread, then sets bit 16 of the interrupt-pending word (4.4) through Wasmtime's epoch interruption, and the running Lisp code notices at its next safe point. See 4.5 for what a JavaScript host can do. |
  | `run_process` | `(spec: i32, length: i32) -> i32` | `sb-ext:run-program`: a NUL-separated spec (argc, argv…, directory, then mode and path for each of stdin/stdout/stderr, then envc and `NAME=VALUE`…; `main.rs` line 190) to run and wait for; returns the exit status, 128 + signal, or -1. A Node host can implement it with `child_process.spawnSync` or return -1 (then `run-program` signals an error). |
  | `process_id` | `() -> i32` | the runtime's `getpid` (scratch file names); return `process.pid`. |

- `env`: three symbols the runtime leaves undefined (`madvise`,
  `list_lisp_threads`, `generate_elfcore_obj`); bind them to functions
  that return 0 or throw. The reference host binds every unknown
  import to a trap.

The instance's exports the host uses: `memory` (the one linear memory,
declared by the runtime: 146 pages initially, 4 GiB maximum, grown by
`memory.grow` as the heap needs; the default dynamic space is 512 MiB,
`--dynamic-space-size` changes it), `__indirect_function_table` (the
shared `funcref` table every Lisp module's functions go into),
`_start`, and the four entry points the Lisp modules import (4.3).

### 4.3 Imports of every Lisp module (the core module and the run-time ones)

The module the host instantiates in `instantiate` imports, in module
`env`: `memory` and `__indirect_function_table` (the runtime's
exports), `thread` (an immutable `i32` global = `register_area`),
`table_base` (an immutable `i32` global = the base), `lisp_unwind` (a
`WebAssembly.Tag` with no parameters, **one tag shared by every
module**: non-local exits throw and catch it across modules), and the
runtime's exported functions `internal_error`, `alloc`, `alloc_list`,
`pending_interrupt`. In module `table`, functions named by a decimal
number: the module calls an assembly routine of the core module by
its table index (`table.get(index)` of the shared table). Nothing
else. `tests/wasm/load-core.mjs` (Sprint 5) instantiates the core
module against stubs of exactly this shape in Node; it is the seed of
the JavaScript `instantiate`.

### 4.4 The register area and the interrupt-pending word

`register_area` is the address, in linear memory, of the Lisp
"register file" (`src/runtime/wasm-lispregs.h`): the runtime allocates
it and passes it to `instantiate`. The host writes one word of it:
the interrupt-pending word at offset 456 (`LISP_REGISTER_AREA_INTERRUPT_PENDING`),
a bit set: 1 = interrupt request (Ctrl-C: Lisp enters `sb-sys:interactive-interrupt`),
16 = the timer expired; the runtime owns the other bits (GC, stack
guard). Compiled code polls the word at every function entry and loop
back edge and calls `pending_interrupt` when it is nonzero. Writing it
from the host is how anything interrupts running Lisp code.

### 4.5 What differs from Wasmtime in V8

- **No epoch interruption.** Wasmtime lets the host run a callback
  while Wasm runs; V8 does not. A JavaScript host can set the bits of
  4.4 only from inside a host call. Practical form: keep the timer
  deadline in JavaScript and check it in the WASI shim's
  `clock_time_get` and `poll_oneoff` (the runtime calls the first
  constantly — `get-internal-real-time` — and the second from every
  sleep, which the port slices; `src/runtime/wrap.c`): when the
  deadline has passed, set bit 16. Timers then fire at the next clock
  read rather than at the next safe point, which is late only for a
  tight loop without clock reads. Ctrl-C from a parent needs a Worker
  and a `SharedArrayBuffer` flag checked the same way, or a
  `terminate()` of the Worker.
- **Synchronous compilation inside a call.** `instantiate` runs while
  the runtime waits, so it must use `new WebAssembly.Module(bytes)`.
  Node allows it at any size; browsers do not on the main thread,
  which is why the plan puts the runtime in a Web Worker.
- **Stack.** Every Lisp call is a Wasm call on the engine's native
  stack; the reference host gives it 128 MB (`max_wasm_stack`) so that
  deep recursion ends in a Lisp `storage-condition` (the port's
  control-stack guard, Sprint 11) rather than an engine trap. Run the
  runtime in a `Worker` with `resourceLimits: {stackSizeMb: 256}`
  (or `node --stack-size` for the main thread) and expect
  "Maximum call stack size exceeded" to appear as an engine
  RangeError where Wasmtime reports "call stack exhausted".
- **No module cache.** V8 recompiles the 34 MB module at every start
  (baseline in about 0.1 s, then tiers up in the background); the
  application can keep one instance alive, or use
  `v8.startupSnapshot`/a compiled-module cache of its own.
- **`proc_exit`.** `(exit)` and `--non-interactive` end in
  `proc_exit`; `node:wasi` with `returnOnExit: true` turns it into a
  return value.

### 4.6 A shape for the embedding

1. `new WASI({...})`, `WebAssembly.compile(sbcl.wasm)`.
2. Instantiate it with `{...wasi.getImportObject(), sbcl_host: {...},
   env: {madvise: () => 0, list_lisp_threads: () => 0, generate_elfcore_obj: () => 0}}`;
   remember `instance.exports.memory` and `__indirect_function_table`.
3. `instantiate(ptr, len, area, base)`: copy the bytes out of
   `memory.buffer` (the buffer object changes after `memory.grow`, so
   always re-read `memory.buffer`), read the `sbcl.core.table` section
   with `WebAssembly.Module.customSections`, grow the table, build
   the import object of 4.3 (the one shared `WebAssembly.Tag`), `new
   WebAssembly.Instance`. Keep the instances alive (their functions
   sit in the table).
4. `wasi.start(instance)` with `args = ["sbcl.wasm", "--core",
   "sbcl.core", "--noinform", "--disable-debugger", ...]`; the REPL
   then runs on the WASI stdin/stdout the shim provides. For a
   request/reply API, drive it with `--eval` forms and a sentinel, or
   feed forms through a custom `fd_read`.
5. Calling Lisp from JavaScript other than through stdin, and
   JavaScript from Lisp (`js_call`), are Sprint 14's `sb-js` contrib:
   not there yet. The mechanism exists (the runtime's `call_into_lisp`
   and the alien interface's `foreign-symbol` cells the linkage table
   fills, `src/runtime/wasm-arch.c`), but no JavaScript-facing entry
   is exported; do not promise it before it is built.

## 5. What works and what does not (for scoping the application)

Works: the whole language (the ANSI suite), `compile`/`compile-file`
/`load` at run time (each produces a module the host instantiates),
`save-lisp-and-die` (also `:executable t` with a launcher), the
condition system and the debugger's REPL (not its frame walking),
timers, deadlines and `with-timeout` (through `set_timer`), streams on
WASI files and standard I/O, `run-program` (through `run_process`),
`disassemble`, the pure-Lisp contribs, ASDF.

Does not work, by design or not yet: threads (`sb-thread` is off; the
plan's phase 4), sockets (`sb-bsd-sockets`; WASI preview 1 has none),
foreign libraries and alien callbacks (`sb-posix`, `sb-grovel`), stack
allocation (`dynamic-extent` declarations are honored as heap
allocation), the debugger's backtrace and stepping, `run-program
:wait nil` and `:stream`, `file-author`. The 32-bit word: fixnums are
30 bits, `(signed-byte 56)` arithmetic is generic and slow (cl-bench's
`crc40` is 110× native).

Sizes and times to plan around: 34 MB module + 77 MB core to load,
about 512 MB of linear memory at rest (the default dynamic space;
`--dynamic-space-size 256MB` is enough for a REPL and small programs),
one Lisp image per instance, no sharing of the memory between
instances.

## 6. How to check an embedding

Compare with the reference host on the same files:

```
# the reference: prints (3 1000 4999950000) then :GC-OK
tools-for-build/wasm-sbcl.sh --core output/sbcl.core --non-interactive --no-userinit --no-sysinit \
  --eval '(progn (print (list (+ 1 2) (length (make-list 1000)) (reduce (function +) (loop for i below 100000 collect i)))) (terpri) (sb-ext:gc :full t) (print :gc-ok) (terpri))'
# a compile at run time (a second module instantiated), catch/throw across modules, a timer
  --eval '(progn (compile (quote f) (quote (lambda (n) (if (< n 2) n (+ (f (- n 1)) (f (- n 2))))))) (print (f 20)) (print (catch (quote x) (funcall (compile nil (quote (lambda () (throw (quote x) 42))))))) (print (handler-case (sb-ext:with-timeout 0.3 (sleep 2) :no) (sb-ext:timeout () :timeout))) (terpri))'
```

A JavaScript host is right when these print the same, when
`(load "file.lisp")` and `(compile-file ...)` work (the second
instantiation path), when a runaway recursion `(defun r (n) (1+ (r n)))`
signals `storage-condition` instead of crashing, and when
`tests/wasm/load-core.mjs output/sbcl-core.wasm` still loads the
module (the stub environment). The regression suite can then run
against the new host by setting `TEST_SBCL_RUNTIME` to a wrapper
script that takes the reference host's command line
(`tests/subr.sh`): `SBCL_RUNTIME --core CORE [options]`.

## 7. Where things are

```
WASM-Manual.md                          build, run, test, debug, troubleshoot
doc/wasm-port/02-design.md              the design (2.2 modules, 2.7 interrupts, 2.9 FFI)
doc/wasm-port/04-sprints.md             the plan; Sprint 14 is the JavaScript host
doc/wasm-port/05-testing.md             what is skipped on the port and why
doc/wasm-port/baselines/                suite and benchmark baselines
wasm/crates/sbcl-wasm-host/src/main.rs  the reference host: the contract, line by line
tests/wasm/load-core.mjs                the Node loader of the core module (Sprint 5)
src/runtime/wasm-arch.c                 the runtime's side: the imports, call_into_lisp, module loading
src/runtime/wasm-lispregs.h             the register area layout (offset 456: interrupt pending)
src/compiler/wasm/func-asm.lisp         the import list every Lisp module has (comment "Modules for compiled code")
Sprints/Sprint12/                       the latest state: what was measured, what is open
```

Build questions: `./build-wasm.sh --help`; the tool chain is pinned in
`tools-for-build/wasm-env.sh` (wasi-sdk 27, wasmtime 45, wasm-tools
1.240, binaryen 123, host SBCL 2.4.8, Rust stable) and downloaded by
`./build-wasm.sh toolchain`.
