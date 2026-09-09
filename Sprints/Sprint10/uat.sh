#!/bin/sh
# Sprint 10 user-acceptance test (plan Sprint 9, "triage and fix", part one):
#   - the classes that killed test processes are fixed: foreign calls
#     (undefined aliens signal, wasi-libc gaps stubbed, sb_nanosleep),
#     the empty-arm unreachable, saving a core under another name, the
#     host's native stack, the C shadow stack across a non-local exit
#   - every baseline failure is classified (triage.md), the unsupported
#     tests carry their tags, the ANSI expected list has its #+wasm entries
#   - the second baseline report lists what remains
#   - nothing regressed: Sprint 9's checks, level 0, level 1
# UAT_FAST=1 skips the Lisp builds and the warm load and checks their
# products; UAT_SKIP_SUITES=1 skips the two suites and checks their logs.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
S=Sprints/Sprint10
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
. tools-for-build/wasm-env.sh
WARM="--noinform --no-sysinit --no-userinit --non-interactive --disable-debugger"
ev() { SBCL_WASM_TIMEOUT=${T:-900} ./run-sbcl.sh $WARM --eval "$1"; }
mkdir -p obj/wasm-build

echo "== toolchain and build"
check "wasi-sdk present" "test -x $WASI_SDK/bin/clang"
check "host builds (sbcl-wasm) and runs the module on its own thread" "./build-wasm.sh host > $S/host.log 2>&1 && grep -q 'stack_size(256 << 20)' wasm/crates/sbcl-wasm-host/src/main.rs"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "build products present (fast mode)" "ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm src/runtime/sbcl.wasm output/sbcl.core output/sbcl-core.wasm"
else
  check "build-wasm.sh lisp runtime warm from scratch" \
    "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/from-xc obj/xbuild/wasm/xc.core obj/xbuild/wasm.core obj/from-self && ./build-wasm.sh --jobs 4 lisp runtime warm > $S/build.log 2>&1 && ls output/sbcl.core output/sbcl-core.wasm"
fi
check "the linkage table maps undefined functions to the guard and has the stack helpers" "grep -q 'undefined_alien_function }, /\\* undefined' src/runtime/wasm-linkage-table.c && grep -q '\"c_stack_restore\"' src/runtime/wasm-linkage-table.c"

echo "== the fixed classes"
ev '(print (let ((s (gensym))) (handler-case (symbol-value s) (unbound-variable (c) (list :caught (eq (cell-error-name c) s))))))' > $S/arm.txt 2>&1
check "an error branch to the first elsewhere chunk lands (the empty-arm unreachable)" "grep -q '(:CAUGHT T)' $S/arm.txt"
ev '(print (handler-case (sb-alien:alien-funcall (sb-alien:extern-alien "no_such_function_xyz" (function sb-alien:int sb-alien:int)) 1) (sb-kernel::undefined-alien-function-error (c) (list :undefined (sb-kernel::cell-error-name c)))))' > $S/undefined-alien.txt 2>&1
check "an undefined alien of a non-void signature signals undefined-alien-function-error with its name" "grep -q '(:UNDEFINED \"no_such_function_xyz\")' $S/undefined-alien.txt"
ev '(print (list (progn (sleep 0.01) :slept) (machine-instance) (not (null (sb-unix:unix-tmpfile))) (handler-case (sb-unix:uid-username 0) (error () :no-user))))' > $S/libc.txt 2>&1
check "sleep, machine-instance, tmpfile and the user database stubs" "grep -q '(:SLEPT \"wasm\" T :NO-USER)' $S/libc.txt"
ev '(flet ((sp () (sb-alien:alien-funcall (sb-alien:extern-alien "c_stack_save" (function sb-alien:unsigned))))) (let ((before (sp))) (dotimes (i 20000) (handler-case (error "x") (error () nil))) (print (list :c-stack (= before (sp))))))' > $S/c-stack.txt 2>&1
check "the C shadow stack pointer is where it was after 20,000 errors caught by handler-case" "grep -q '(:C-STACK T)' $S/c-stack.txt"
ev '(let ((a (make-array 64 :element-type (quote bit) :initial-element 1))) (funcall (compile nil (quote (lambda (a) (declare (type (simple-array bit (64)) a)) (setf (aref a 31) 0) (setf (aref a 63) 0)))) a) (print (list :bits (aref a 31) (aref a 63) (aref a 30))))' > $S/bits.txt 2>&1
check "a constant bit index at the top of a word compiles and stores" "grep -q '(:BITS 0 0 1)' $S/bits.txt"
rm -f obj/wasm-build/uat10.core obj/wasm-build/uat10-core.wasm
ev '(progn (defvar *uat10* :saved) (sb-ext:save-lisp-and-die "obj/wasm-build/uat10.core"))' > $S/save.txt 2>&1
SBCL_WASM_TIMEOUT=300 tools-for-build/wasm-sbcl.sh --core obj/wasm-build/uat10.core $WARM --eval '(print (list :restarted *uat10*))' > $S/save-restart.txt 2>&1
check "a core saved under another name gets its module and restarts" "ls obj/wasm-build/uat10-core.wasm && grep -q '(:RESTARTED :SAVED)' $S/save-restart.txt"
SBCL_WASM_TIMEOUT=300 ./run-sbcl.sh $WARM --eval '(labels ((f (n) (if (= n 0) 0 (1+ (f (1- n)))))) (f 100000000))' > $S/exhaust.txt 2>&1
check "a runaway recursion is a trap, not a host abort" "grep -q 'call stack exhausted\|out of bounds memory access' $S/exhaust.txt && ! grep -q 'overflowed its stack' $S/exhaust.txt"

echo "== triage, tags, expected list"
check "triage.md classifies every file of the first baseline" "test \$(grep -c '^| \`' $S/triage.md) -ge 108"
check "the unsupported tests carry :skipped-on :wasm tags and file skips with reasons" "grep -q ':skipped-on :wasm) ; no-signals' tests/hash-cache.pure.lisp && grep -q 'skip-file' tests/timer.impure.lisp && grep -q 'SBCL_WASM' tests/subr.sh tests/foreign.test.sh"
check "the #+wasm ANSI expected entries and the driver's comparison" "grep -q '#+wasm (list \"FILE-AUTHOR.1\"' tests/ansi-tests.sh && grep -q 'wasm-ansi-compare.lisp' tests/wasm-ansi-tests.sh && grep -q 'riscv wasm' tests/test-funs.lisp"

echo "== the suites and the second baseline"
if [ "${UAT_SKIP_SUITES:-0}" != 1 ]; then
  check "tests/run-tests.sh across all files (wasm-parallel-exec.sh) runs to completion" "(cd tests && SBCL_WASM_TEST_TIMEOUT=900 sh ./wasm-parallel-exec.sh -j 3 > ../$S/regress.log 2>&1); grep -q '^==== Summary' $S/regress.log"
  check "tests/ansi-tests.sh runs to completion and compares with the expected list" "(cd tests && sh ./ansi-tests.sh > ../$S/ansi.log 2>&1); grep -q '^unexpected failures:' $S/ansi.log"
else
  check "the regression run completed (suites skipped: $S/regress.log)" "grep -q '^==== Summary' $S/regress.log"
  check "the ANSI run completed (suites skipped: $S/ansi.log)" "grep -q '^unexpected failures:' $S/ansi.log"
fi
check "the second baseline report is written" "mkdir -p doc/wasm-port/baselines && sh $S/baseline.sh $S/regress.log tests/ansi-test/results.txt > doc/wasm-port/baselines/sprint-9.txt && grep -q '^files: ' doc/wasm-port/baselines/sprint-9.txt && grep -q '^== the ANSI suite' doc/wasm-port/baselines/sprint-9.txt"
check "fewer files fail than in the first baseline" "test \$(sed -n 's/^files: [0-9]*  passed: [0-9]*  failed or incomplete: \\([0-9]*\\).*/\\1/p' doc/wasm-port/baselines/sprint-9.txt) -lt \$(sed -n 's/^files: [0-9]*  passed: [0-9]*  failed or incomplete: \\([0-9]*\\).*/\\1/p' doc/wasm-port/baselines/sprint-8.txt)"
check "no regression file dies of a trap the sprint fixed (unreachable, indirect call type mismatch)" "! grep -q 'unreachable\\|indirect call type mismatch' doc/wasm-port/baselines/sprint-9.txt"

echo "== regressions (Sprint 9)"
ev '(progn (with-open-file (s "obj/wasm-build/uat10.lisp" :direction :output :if-exists :supersede) (write (quote (defun uat10-f (n) (if (< n 2) n (+ (uat10-f (- n 1)) (uat10-f (- n 2)))))) :stream s)) (compile-file "obj/wasm-build/uat10.lisp") (load "obj/wasm-build/uat10.fasl") (print (uat10-f 15)) (disassemble (quote car)))' > $S/compile-file.txt 2>&1
check "compile-file, load and disassemble" "grep -q '^610' $S/compile-file.txt && grep -q 'the core module' $S/compile-file.txt"
SBCL_WASM_TIMEOUT=900 ./run-sbcl.sh $WARM --eval '(require :sb-md5)' --eval '(print (sb-md5:md5sum-string "abc"))' > $S/md5.txt 2>&1
check "(require :sb-md5)" "grep -q '#(144 1 80 152 60 210 79 176 214 150 63 125 40 225 127 114)' $S/md5.txt"
ev '(print (with-output-to-string (s) (sb-ext:run-program "/bin/sh" (list "-c" "echo out") :output s)))' > $S/run-program.txt 2>&1
check "run-program through the host" "grep -q '\"out' $S/run-program.txt"
echo "== regressions (levels 0 and 1)"
if tests/wasm/run-level0.sh > $S/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' $S/level0.log) checks"; else bad "level-0 (see $S/level0.log)"; fi
if [ "${UAT_FAST:-0}" != 1 ] || [ ! -f obj/xbuild/wasm/after-xc.core ]; then
  check "after-xc core for the level-1 suite" "Sprints/Sprint5/after-xc.sh > $S/after-xc.log 2>&1 && ls obj/xbuild/wasm/after-xc.core"
fi
if XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > $S/level1.log 2>&1; then ok "level-1: $(grep '^level1:' $S/level1.log)"; else bad "level-1 (see $S/level1.log)"; fi

echo
echo "passed=$pass failed=$fail"
[ $fail = 0 ]
