# Sprint 6 — verification and further study

## 1. Exit criteria (plan Sprint 5, "runtime port")

| Criterion | Result |
|---|---|
| `src/runtime/sbcl.wasm --version` and `--help` work | yes, under `tools-for-build/wasm_run.sh` (`test.md`) |
| `coreparse` loads the cold core | yes: page table, spaces and the linkage table are set up from `obj/xbuild/wasm.core`; all 168 foreign symbols resolve |
| the core module instantiates against the runtime's memory and table | yes, through `sbcl_host.instantiate` (table grown to 47,588 entries); 24 s to compile once, 0.8 s from Wasmtime's cache afterwards |
| `call_into_lisp` reaches the cold-init entry function (which may then fail) | yes: `!COLD-INIT` runs through the stream and signal-function initialization and stops in `!printer-control-init` (`test.md`) |

## 2. What running the core taught (details in `develop.md`, section 3)

Four defects that the level-1 differential suite could not see, because
its cases are single-entry components without full calls that use
constants after returning and without foreign calls:

1. genesis numbered a component's entries in the opposite order from the
   dumper (multi-entry components only);
2. the wasm backend had no `symbol-hash`/`symbol-name-hash` VOPs, so the
   self-translating definitions in `symbol.lisp` looped by tail call;
3. `foreign-symbol-sap` produced a table index nothing filled; it now
   loads the linkage cell the runtime fills;
4. after a full call the caller's CODE register held the callee's code
   object, so every constant the caller read afterwards came from the
   wrong code header (a `(!signal-function-cold-init)` became a
   zero-argument `(floor1)`). The fix saves CODE in the caller's frame
   slot `code-save-offset` (reserved since Sprint 4 for the debugger)
   before the call and reloads it after; the unwind routine already
   restored CODE from the catch/unwind block.

Next defect, left for Sprint 7: a frame or register slot is overwritten
inside `%make-hash-table` called from `make-pprint-dispatch-table`
(`test.md`).

Lesson for the test plan: level-1 cases should include a multi-entry
component (a `defun` with a local `lambda` that is also an entry), a
function that reads a constant after a full call returns, and a foreign
call; the Sprint 7 plan picks these up as the first new cases.

## 3. Open items and deviations from the plan

- **grovel-headers under `wasm_run.sh`** (planned for this sprint) is
  deferred: `grovel-headers.c` does not compile for wasm32-wasip1 without
  gates for `sys/wait.h`, termios, `dlfcn.h`, interval timers and the FPE
  codes, and its output replaces
  `crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp`,
  which today carries x86-64 type widths (`clock-t`, `nfds-t`, `dev-t`
  are 64-bit there; wasm32's are not all). Changing it means another
  pass-1/pass-2 rebuild and touches `unix.lisp`; it belongs with the
  streams/OS-layer sprint, where the constants matter.
- `make-config.sh` has no `wasi` case; `wasm-build-runtime.sh` configures
  the runtime directly. To be folded into `make-config.sh` when the
  build is driven from `make.sh` (Phase 3).
- Timers: `sb_getitimer`/`sb_setitimer` return `ENOSYS`. Host-side timers
  (through the epoch mechanism) are planned with interrupt delivery.
- Interrupts: Ctrl-C reaches the register area's pending word, but no
  Lisp code polls it yet and `pending_interrupt` is a no-op; the runtime
  also cannot deliver anything at a safe point. Sprint 7 (Lisp side of
  errors and interrupts).
- The `env` imports the runtime leaves for the host to trap (`dlopen`,
  `dlsym`, `kill`, `pipe`, `getuid`, `gethostname`, ...) are the
  linkage-table names of functions WASI has no equivalent for; calling
  one aborts with a message naming it. Each becomes either a real
  implementation or a Lisp-visible error as the OS layer is ported.
- No guard pages: `os_protect` is a no-op, so control-stack exhaustion
  is not detected (it would overwrite the binding stack). A bounds check
  in `xep-setup-sp`/`allocate-frame` or a Wasm-side guard is needed
  before the debugger sprint.
- `brief_print` (ldb's object printer) prints symbols as "other pointer"
  on this target; `wasm-arch.c` has its own name printer. Worth fixing in
  `print.c` when ldb is looked at.
- The Wasmtime cache directory is the user's default
  (`~/.cache/wasmtime`); the cached core module is 82 MB. `SBCL_WASM_*`
  environment variables are read by the host and the runtime; they are
  documented in `develop.md` only.
