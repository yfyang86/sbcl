# Sprint 14 — development record (the browser host)

Plan: `doc/wasm-port/04-sprints.md`, Phase 3, "Sprint 14: browser
host". Contract: `SBCL-Handoff.md` section 4; the reference
implementation is `wasm/crates/sbcl-wasm-host/src/main.rs`.

## 1. The pieces (`wasm/web/`)

- **`sbcl-host.js`** — the `sbcl_host` contract (the handoff's 4.2 and
  4.3): `instantiate` synchronous (`new WebAssembly.Module` + `new
  WebAssembly.Instance`), reading the module bytes out of the runtime's
  linear memory (the buffer re-read every time: it detaches on
  `memory.grow`), parsing the `sbcl.core.table` custom section,
  growing the shared table, resolving the `table` module's
  index-named imports from it, and building the `env` imports of every
  Lisp module (the shared `WebAssembly.Tag`, the `thread` and
  `table_base` globals, the runtime's `internal_error`/`alloc`/
  `alloc_list`/`pending_interrupt`). `set_timer` keeps a deadline in
  JavaScript — V8 has no callback while Wasm runs, so the timer's bit
  16 (and a Ctrl-C's bit 1) are OR-ed into the interrupt-pending word
  at the WASI clock reads and polls, the handoff's 4.5 form.
  `run_process` answers -1 (nothing can spawn); `process_id` is 1.
  `trapUnknownImports` fills what the two namespaces do not cover with
  traps, the reference host's `define_unknown_imports_as_traps`.
- **`wasi.js`** — WASI preview 1 over an in-memory file system (a map
  of absolute path to bytes; directories are the path prefixes): the
  24 calls the runtime makes, with stdio as callbacks, stdin as a
  reader interface, files writable through a chunked buffer gathered
  until `fd_close` (what `compile-file` writes lands in the map). The
  preopen is fd 3 = `/`, holding the core pair the page fetched.
- **`worker.js`** — the worker: fetches runtime, core and core module,
  instantiates the runtime, calls `_start` on its own thread, and
  talks the message protocol the page and the tests use. The REPL is
  "up" when the first `* ` prompt appears in stdout (that is the
  startup time the records carry).
- **`ring.js`** — the input ring: see section 2, the sprint's one real
  lesson.
- **`index.html`, `repl.js`, `repl.css`** — the REPL page; `?load=`
  fetches extra files into the worker's file system before the start
  (the test data path).
- **`serve.mjs`** — the dev server: the page, the worker and the build
  products, `/data/` for test files, and the COOP/COEP headers that
  make the page crossOriginIsolated (the ring's SharedArrayBuffer).
- **`node-smoke.mjs`** — the same host code under Node (`--experimental-
  wasm-exnref` on Node 22; Node 24 has the proposal on), the fast
  iteration path and the in-process embedding of the handoff's
  section 3.
- **`contrib/sb-js/`** — the skeleton: the package, `js-call`, its
  `js-call-error` ("no JavaScript entry point in this host"), the
  `*js-host-available*` seam a real entry point will set. No runtime
  change: the entry point the design wants (`call_into_lisp` and a
  host function behind the linkage table) is future work, and the
  skeleton fixes the interface it will plug into.

## 2. The lesson: a worker inside Wasm cannot take messages

The first REPL sent input as `postMessage({type: "stdin", ...})` — the
form every worker example uses — and the REPL read nothing: SBCL's
reader sat in `fd_read` forever. The cause is structural, not a bug to
patch: the worker's single thread is executing `_start`'s Wasm for the
whole session (the REPL is a loop inside it), so the worker's message
queue is never drained — the handler for `stdin` queues behind a call
that never returns. Standard input has to reach the blocked `fd_read`
without the worker's own thread: a single-producer single-consumer
byte ring over a `SharedArrayBuffer` (`ring.js`), the page writing and
`Atomics.notify`-ing from its own thread, the worker's read blocking
in `Atomics.wait`. The worker sends the buffer to the page before the
start; the page imports the same `RingStdin` class over it. This needs
the page crossOriginIsolated, hence the server's COOP/COEP headers;
without them the ring is a plain queue and the REPL sees input at the
next poll (the wasm `poll_oneoff`, called for every sleep) — degraded,
not broken. Anything else that must reach a running SBCL worker
(interrupts were the other candidate) goes the same way or through a
word the runtime polls.

## 3. The WASI shim's shape

Twenty-four calls, three groups. The file group is a path map:
`path_open` resolves against fd 3, reads hand out the bytes, writes
(including `compile-file`'s `:if-exists :supersede`) gather chunks
until close; `fd_filestat_get`/`path_filestat_get` answer for files
and prefix-directories. The clock group is where the timer lands
(section 1). The poll group (`poll_oneoff`) is the port's sliced
sleep: clock subscriptions sleep `Atomics.wait`, stdin subscriptions
break on `ready()`, and the subscription union's layout (tag at
offset 8, the fd_read fd there too, the clock timeout at 16) cost one
debugging round to get right. `proc_exit` throws a `ProcExit` out of
`_start`, which the worker reports as the exit code.

## 4. What V8 needed

Nothing beyond what Sprint 5 measured: tail calls and the exnref
exception proposal are on in current Chromium and Firefox (and Node
24); Node 22 still wants `--experimental-wasm-exnref`. The 44 MB core
module compiles in the worker in about 0.2 s (Chromium; 1.3 s in
Firefox) — the baseline compiler, no cache, on every start, as the
handoff's 4.5 said. Deep recursion lands in V8's "Maximum call stack
size exceeded" instead of Wasmtime's "call stack exhausted" — the
worker's default stack has been enough for everything the sprint ran.

## 5. The bugs worth keeping

- **`postMessage` of a view clones its buffer.** The first `stdout`
  forwarding handed the WASI shim's `Uint8Array` (a view into the
  runtime's 512 MB linear memory) to `postMessage` and Chrome refused:
  "Data cannot be cloned, out of memory". Every byte the runtime
  writes is copied (`bytes.slice()`) before it crosses the boundary.
- **The wrong wait for "the REPL is up".** The first worker posted its
  startup time in the `finally` of `_start` — which runs when Lisp
  exits, not when the prompt appears. The page now learns the startup
  when the worker sees the first `* ` in stdout.
- **`sb-js.asd` needs the guard form.** `make-contrib.lisp` asserts
  the asd's first form is the `(error "Can't build contribs with
  ASDF")` marker; the defsystem follows it.

## 6. The measurements

On the development machine (Apple silicon, the files served from
localhost, no engine cache): fetch+boot to the first REPL prompt 0.2 s
in Chromium and 1.3 s in Firefox (the module compiles anew each
start); the whole 8-test Playwright suite, four tests per browser,
17–22 s. Sizes: core module 44,423,507 bytes, runtime 1,407,795,
core 78,754,452. The Node smoke run evaluates `(print (+ 1 2))` and
exits in about 170 ms.
