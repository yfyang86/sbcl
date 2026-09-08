# 5. Test strategy

The existing SBCL test infrastructure is reused wherever it can be, and
two new lower levels are added so that the backend is tested before the
runtime can boot. Every level runs in CI; the level at which a change is
tested is the level at which it is developed.

## 5.1 Levels

| Level | What | Where it runs | Oracle | Available from |
|---|---|---|---|---|
| 0 Assembler and module writer | LEB128 encoders, every `define-instruction`, module sections, names section, control-flow lowering on hand-built label streams | host SBCL, in the cross-compiler image (`xc.core`) built by `crossbuild-runner` | `wasm-tools validate` and `wasmprinter` round-trip through `sbcl-wasm-tools`; golden `.wat` files under `tests/wasm/golden/` | Sprint 1 |
| 1 Compiler-only differential | Lisp forms cross-compiled to a module and executed under Wasmtime with a mini-runtime (a 200-line C file providing a thread struct, a bump allocator, `print`, error trap) with no core | host SBCL compiles, `sbcl-wasm-test` executes | the same form evaluated in the host SBCL; results compared as printed representations | Sprint 2 |
| 2 Runtime unit tests | `gc-unit-tests.c`, coreparse on synthetic cores, linkage table resolution, `os_alloc_gc_space`, stack limit checks | Wasmtime | assertions in C | Sprint 5 |
| 3 Boot smoke | `--version`, `--help`, cold core to REPL, `--eval`, `--load`, `--script`, `save-lisp-and-die` and restart | Wasmtime via `sbcl-wasm` | `tests/core.test.sh`, `init.test.sh`, `script.test.sh`, `save*.test.sh` where applicable | Sprint 6–7 |
| 4 SBCL regression suite | `tests/run-tests.sh` with all categories | Wasmtime, `parallel-exec.sh` across files | exit code 104; `:skipped-on`/`:broken-on`/`:fails-on :wasm` annotations | Sprint 8 |
| 5 ANSI suite | `tests/ansi-tests.sh` | Wasmtime | expected-failure list with `#+wasm` entries | Sprint 8 |
| 6 Contribs | `tests/sb-*.impure.lisp` | Wasmtime | as level 4 | Sprint 8, 13 |
| 7 Browser | boot, REPL, `compile`, a curated subset of pure tests executed inside the worker and reported through `postMessage` | Playwright, Chromium and Firefox | pass/fail per test | Sprint 14 |
| 8 Performance | cl-bench, `benchmarks/`, build time of `make-target-2`, core module size, startup time | Wasmtime and Node, nightly | previous run; a regression over 10 percent fails the nightly | Sprint 11 |
| 9 Differential fuzzing | random arithmetic and type-test forms (extending `tests/arith-combinations.pure.lisp` and `compiler-test-util.lisp`) compiled on x86-64 and wasm, results compared | Wasmtime | host SBCL | Sprint 10 |

## 5.2 Conventions in the regression suite

- `:skipped-on :wasm` means unsupported by design in the current phase.
  The reason goes in a comment on the same line, using a fixed vocabulary
  so the skip list can be reported by category: `no-fork`, `no-signals`,
  `no-threads`, `no-dlopen`, `no-float-traps`, `no-breakpoints`,
  `no-mprotect`, `depth`, `timing`.
- `:broken-on :wasm` means intended to work and tracked by an issue
  number in the comment.
- `:fails-on :wasm` is not used; a test that fails is either fixed or one
  of the above.
- Feature symbols visible to tests: `:wasm`, `:wasm32` or `:wasm64`,
  `:wasi`, `:no-float-traps` (already appended by `test-funs.lisp` for
  trapless targets), and the absence of `:sb-thread`,
  `:os-provides-dlopen`, `:c-stack-is-control-stack`.
- Prefer `(:vop-existsp NAME)` gates for tests of optional VOPs over
  arch names, as the suite already does.

Expected initial skip surface, by file family: `save*.test.sh` variants
that check ELF layout (`elfcore`, `elf-sans-immobile`), `foreign.test.sh`
(builds shared objects), `run-program*`, `threads*`, `interrupt*`,
`signals`, `kill-non-lisp-thread`, `futex-wait`, `fcb-threads`,
`x86-64-codegen`/`arm64-codegen`, `simd-pack*`, `sb-sprof` timing tests,
`relocation.test.sh`, `mmap`-based `gc` tests. Target after Sprint 10:
under 150 `with-test` forms skipped out of about 5,300.

## 5.3 Running the suites against the Wasm build

`tests/subr.sh` gains a Wasm branch: when `src/runtime/sbcl.wasm` exists,
`SBCL_RUNTIME` becomes `wasm/target/release/sbcl-wasm src/runtime/sbcl.wasm`
and `run_sbcl` passes `--core` through unchanged. Shell tests that create
files use the current directory, which the host preopens. Tests that
spawn `sbcl` recursively (`run-in-child-sbcl`, `run-program` of the
runtime) work under Wasmtime because WASI cannot spawn processes but the
*host* can: the impure runner already goes through `run-program`, so for
Wasm it goes through a host import `sbcl_host.spawn_sbcl` limited to
spawning another instance of the same runtime and core. This is the one
place where the standalone host has a capability the browser host does
not, and the browser runs only level 7.

Time budget: with about 380 test files and a Wasmtime startup plus core
load near 300 ms, the impure and shell categories cost roughly two
minutes of process starts on top of the tests themselves;
`parallel-exec.sh` with four workers keeps the full run under the native
`--slow` run's wall time in CI.

## 5.4 Compiler-only differential tests in detail

This is the level that makes Phase 1 testable and is new to SBCL.

- `tests/wasm/diff/*.lisp` hold forms grouped by VOP family, for example
  `arith.lisp`, `calls.lisp`, `values.lisp`, `nlx.lisp`, `float.lisp`,
  `arrays.lisp`. Each entry is `(form &key expected)`; the expected value
  defaults to evaluating the form in the host.
- `sbcl-wasm-test` invokes the cross-compiler image with
  `(sb-wasm-test:compile-to-module form)`, receives a module plus a
  description of the argument registers, links it against
  `tests/wasm/minirt.wasm`, runs it, and prints the result through the
  mini-runtime's `print` import.
- The mini-runtime provides a static space with `NIL` and `T`, a thread
  struct, a bump allocator region, `alloc` as a slow path that grows the
  region, `print` for fixnums, characters, and simple strings, and an
  `error` import that records the trap number. Nothing else. Forms that
  need more than this (hash tables, generic functions) belong to level 4.
- Failures print both modules' `.wat` and the register file state at
  exit.

## 5.5 Test harness changes list

1. `tests/subr.sh`: Wasm branch (5.3).
2. `tests/test-util.lisp`: no change; `:wasm` is an ordinary feature.
3. `tests/test-funs.lisp:41-45`: extend the `:no-float-traps` rule to `:wasm`.
4. `tests/ansi-tests.sh`: `#+wasm` expected failures.
5. `tests/run-tests.lisp`: `run-in-child-sbcl` through the host spawn import when `#+wasm`.
6. `tests/wasm/`: levels 0, 1 and 9.
7. `wasm/crates/sbcl-wasm-test`: the runner for levels 0, 1, 2, 9 and the
   benchmark driver for level 8.
8. `wasm/web/tests/`: Playwright, level 7.
9. `.github/workflows/linux-wasm.yml`: everything above on push; browser
   and performance jobs nightly.
