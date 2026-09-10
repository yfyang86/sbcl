# Sprint 14 — test record

The build under test: the tree at the sprint14 branch on top of the
Sprint 13 merge, built by `./build-wasm.sh lisp opt runtime grovel
warm contrib` — the same products as Sprint 13's final build (the
compiler backend is untouched; the only tree changes are the new
`wasm/web/`, `tests/wasm/web/`, `contrib/sb-js/` and the sb-js entry
in contrib/Makefile).

## 1. The browser host

`Sprints/Sprint14/uat.sh` (11 checks, all green):

- the pieces exist and the build products are current;
- the Node smoke run (`wasm/web/node-smoke.mjs`, the same host code as
  the worker without a browser): `(print (+ 1 2))` → 3, exit 0 in
  ~170 ms;
- the dev server serves the page with both cross-origin headers;
- the Playwright suite in Chromium and Firefox: **8 passed** (four
  tests per browser: boot to the REPL, the REPL round trip
  (`(+ 1 2)` → 3, `(values :a :b)` → both), a run-time `compile`
  (`(compile 'sq)` then `(sq 12)` → 144), and the pure-checks file
  loaded and run in the worker: 22/22 checks);
- `sb-js` builds, loads, and `js-call` signals its `js-call-error`.

Startup and size (the exit criterion's recordings): fetch+boot to the
first REPL prompt **0.2 s in Chromium, 1.3 s in Firefox** (the 44 MB
core module compiled anew each start, no engine cache); core module
44,423,507 bytes, runtime 1,407,795, core 78,754,452. The whole
8-test suite runs in 17–22 s.

## 2. The differential suites (nothing regressed)

`./build-wasm.sh test` on the branch: level 0, 16 checks green;
level 1, **163 modules, 444/444 cases** — identical to Sprint 13's
final run.

The first level-1 run of the sprint reported 0/444, every case "type
mismatch with parameters" — Sprint 13's s13d symptom. Not a
regression: the machine's `wasm/target/release/sbcl-wasm-test` and
`tests/wasm/minirt.wasm` were both built before the Sprint 13 merge
was pulled (09:16 against a merge at 21:33 local), and `run-level1.sh`
rebuilds neither when the files exist. Rebuilding both made the suite
green with the committed sources unchanged. `run-level1.sh` now
rebuilds the mini-runtime when `minirt.c` is newer than `minirt.wasm`
(the rig's staleness `build-wasm.sh host` already covers, per Sprint
13's record).

## 3. The regression and ANSI suites

Not re-run this sprint: the compiler backend, the runtime and the core
are byte-for-byte Sprint 13's (no source under `src/` changed), and
those suites were Sprint 13's final runs on exactly these sources
(`Sprints/Sprint13/test.md`; baselines
`doc/wasm-port/baselines/sprint-13.txt`). The sprint's changes are
host-side; a `wasm-dev` run of `./build-wasm.sh regress ansi` after
the merge would be the belt-and-braces check.
