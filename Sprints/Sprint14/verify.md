# Sprint 14 — verification and further study

## 1. Exit criteria (the plan's "Sprint 14: browser host")

| Criterion | Result |
|---|---|
| `wasm/web`: Web Worker running the runtime and core, WASI shim, `sbcl_host` implementation, synchronous module instantiation in the worker, a REPL page | met: `worker.js`, `wasi.js`, `sbcl-host.js` (the whole `SBCL-Handoff.md` 4 contract), `index.html`/`repl.js`; `serve.mjs` ties them together with the COOP/COEP headers the input ring needs |
| `sb-js` contrib skeleton (`js_call`) | met: `contrib/sb-js/` — the package, `js-call`, its error; built with the contribs, loaded and exercised under the reference host |
| the Playwright suite: boot, REPL round trip, `compile` of a function, a subset of pure tests executed in the worker | met: `tests/wasm/web/repl.spec.mjs`, four tests, run in both browsers |
| the REPL page runs in Chromium and Firefox | met: Chromium 8/8 (via the installed Google Chrome) and Firefox 8/8 (Playwright's Firefox 148) — `Sprints/Sprint14/playwright.txt` |
| the Playwright suite is in the nightly CI | met: `.github/workflows/linux-wasm.yml` runs it (Chromium) after the build on every push; `PLAYWRIGHT_FIREFOX=1` adds Firefox |
| startup time and core module size recorded | met: 0.2 s (Chromium) / 1.3 s (Firefox) to the first REPL prompt, module 44,423,507 bytes (`test.md`, `develop.md` section 6) |

## 2. What the sprint taught

- **A worker inside Wasm cannot take messages.** The REPL's standard
  input cannot go through `postMessage`: the worker's thread is the
  Wasm `_start` call for the whole session, and nothing drains its
  message queue until Lisp exits. Input that must reach a blocked read
  goes through shared memory (`ring.js`: a byte ring on a
  SharedArrayBuffer, the page writing and notifying, the WASI `fd_read`
  waiting), and anything else reaches the worker the same way or
  through a word the runtime polls. The handoff's protocol section is
  updated for it.
- **Bytes crossing the boundary are copied.** Handing WASI's write
  buffers — views into the runtime's linear memory — to `postMessage`
  asks the structured clone to copy the whole (half-gigabyte) backing
  buffer and fails with "out of memory". Every stdout/stderr chunk is
  sliced before it crosses.
- **V8 needs nothing extra.** Current Chromium, Firefox and Node 24
  run the port's feature set (tail calls, exnref) without flags; only
  Node 22 wants `--experimental-wasm-exnref`. The 44 MB core module
  compiles in the worker in 0.2 s with no cache — the "no module
  cache" concern of the handoff's 4.5 measured at a fifth of
  Wasmtime's cached time.
- **Stale build artifacts read as regressions.** The 0/444 level-1
  false alarm (`test.md` section 2) was the machine's pre-merge rig
  and mini-runtime; `run-level1.sh` now rebuilds the mini-runtime when
  its source is newer, extending Sprint 13's "rebuild the rig" lesson
  to every artifact the suites cache.

## 3. Open items (the backlog)

1. **`js_call` for real** (`develop.md` section 1): a runtime entry
   point the browser host fills — `call_into_lisp`'s mirror — with
   values marshalled over the linear memory; the `sb-js` skeleton's
   `*js-host-available*` seam and error are the interface. Synchronous
   return needs the same shared-memory discipline as the input ring.
2. **A persistent file system** (OPFS, or IndexedDB behind the WASI
   shim's file map): `compile-file` products and `save-lisp-and-die`
   cores currently live only in the worker's memory for the session.
3. **Module transfer**: the browser recompiles the 44 MB module every
    start (0.2 s; harmless) and re-fetches 124 MB of core+module per
    page load (localhost-fast; a deployed page wants HTTP caching
    headers, which `serve.mjs`'s `cache-control: no-store` now
    deliberately defeats for development).
4. **The timer's latency**: interrupts (timer bit, Ctrl-C bit) are
   delivered at the WASI clock reads and polls — late for a tight Lisp
   loop that reads no clock. A `SharedArrayBuffer` flag polled at the
   safe point would tighten it (the handoff's 4.5 already sketches
   this for Ctrl-C).
5. Carried from Sprint 13: the call sequence (5–25× on call-heavy
   kernels), `ctak`/`crc40`, the float registers, the stackifier
   fallbacks, the debugger support, `FORMAT.E.26`.
