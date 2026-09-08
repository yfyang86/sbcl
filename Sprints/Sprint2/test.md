# Sprint 2 — test (UAT)

Acceptance criteria are the sprint's exit criteria from
`doc/wasm-port/04-sprints.md` (Phase 1, "target definition and assembler"):
the host builds the wasm cross-compiler from the new backend, genesis
pass 1 writes the headers, the crossbuild image builds, and the level-0
assembler and module-writer tests pass with every module validated by
wasm-tools and executed by wasmtime.

`uat.sh` rebuilds everything (about seven minutes); `UAT_FAST=1 uat.sh`
checks the products instead. Run from the repository root:

```
Sprints/Sprint2/uat.sh
```

## Result

```
== configuration
PASS  make-config accepts --arch=wasm
PASS  features: :wasm :soft-card-marks :gencgc, no :64-bit
== make-host-1 (cross-compiler and genesis headers)
PASS  make-host-1 succeeds for the wasm backend
PASS  sbcl.h: LISP_FEATURE_WASM, 32-bit words
PASS  sbcl.h: soft card marks, 32 cards per 32 KiB page
PASS  sbcl.h: static space at 17 MiB, 4-byte linkage entries
PASS  no riscv instruction names remain in the backend
== crossbuild-runner pass-1
PASS  crossbuild pass-1 builds obj/xbuild/wasm/xc.core
== level 0
PASS  level-0: 10 checks, all modules validate and run
PASS  level-0 covers every module writer section kind
PASS  level-0 exercised exception handling and tail calls under wasmtime

passed=11 failed=0
```

Level-0 detail (`tests/wasm/run-level0.sh`):

```
level0 lisp checks: 27, failures: 0
PASS validate add.wasm
PASS validate arith.wasm
PASS validate eh.wasm
PASS validate sections.wasm
PASS run add.add(2 3 ) = 5
PASS run add.add(-7 7 ) = 0
PASS run arith.compute() = 1013666
PASS run eh.tail(1000000 ) = 1000000
PASS run eh.catcher() = 42
PASS name section
level0: all passed
```

Regression: `check-x86-64-host1.sh` ran `make-host-1` for x86-64 with the
same generic files and it succeeded (`x86-64 make-host-1 exit=0`).

## What each check establishes

| Check | Establishes |
|---|---|
| make-host-1 succeeds | every backend file the build order names compiles and loads into the cross-compiler; every VOP, move function, `defknown` and hook the front end references exists |
| sbcl.h contents | genesis reads the new `parms.lisp`: word size, page and card geometry, space layout and linkage entry size are what design 2.1–2.3 specify |
| no riscv instruction names remain | the scaffold from Sprint 1 is gone; the backend emits only Wasm |
| crossbuild pass-1 | the host-only development loop of design 3.3 works for the new backend |
| level-0 Lisp checks | LEB128 and constant encodings, control-note recording, fixup notes |
| validate *.wasm | the module writer produces well-formed Wasm 3.0 for every section kind, including tags, element and data segments |
| run add/arith/eh | the encoded instructions have the intended semantics under a real engine, including `try_table`/`throw` and `return_call` |
| name section | debug names survive, as the profiler and disassembler will need |
