#!/bin/sh
# Sprint 9 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 8, "self-hosting and the first baseline"):
#   - compile-file and load of fasls; disassemble
#   - the pure-Lisp contribs build and load
#   - run-sbcl.sh, tests/subr.sh, parallel-exec.sh and make-target-contrib.sh
#     run the runtime through sbcl-wasm; run-program works through the host
#   - tests/run-tests.sh runs to completion and the baseline report lists
#     every failing test; tests/ansi-tests.sh runs to completion
#   - nothing regressed: the Sprint 8 saved-core checks, level 0, level 1
# UAT_FAST=1 skips the Lisp builds and the warm load and checks their
# products; UAT_SKIP_SUITES=1 skips the two test suites (about two hours)
# and checks the existing baseline report.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
S=Sprints/Sprint9
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
. tools-for-build/wasm-env.sh
RUN=tools-for-build/wasm_run.sh
WARM="--noinform --no-sysinit --no-userinit --non-interactive"
ev() { SBCL_WASM_TIMEOUT=${T:-900} ./run-sbcl.sh $WARM --eval "$1"; }

echo "== toolchain"
check "wasi-sdk present" "test -x $WASI_SDK/bin/clang"
check "host builds (sbcl-wasm) with run_process" "./build-wasm.sh host > $S/host.log 2>&1 && ls wasm/target/release/sbcl-wasm && grep -q run_process wasm/crates/sbcl-wasm-host/src/main.rs"

echo "== Lisp side, runtime, warm load"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "build products present (fast mode)" "ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm src/runtime/sbcl.wasm output/sbcl.core output/sbcl-core.wasm"
else
  check "build-wasm.sh lisp runtime warm from scratch" \
    "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/from-xc obj/xbuild/wasm/xc.core obj/xbuild/wasm.core obj/from-self && ./build-wasm.sh --jobs 4 lisp runtime warm > $S/build.log 2>&1 && ls output/sbcl.core output/sbcl-core.wasm"
fi
check "the runtime's linkage table has run_process, environ, sysconf" "grep -q '\"wasm_run_process\"' src/runtime/wasm-linkage-table.c && grep -q '\"environ\"' src/runtime/wasm-linkage-table.c && grep -q '\"sysconf\"' src/runtime/wasm-linkage-table.c"

echo "== routing"
ev '(print (list *default-pathname-defaults* sb-ext:*runtime-pathname* (find :wasm32 *features*) (find :wasi *features*)))' > $S/route.txt 2>&1
check "run-sbcl.sh runs the saved core through sbcl-wasm; paths are the host's; :wasm32 :wasi" "grep -q \"#P\\\"$ROOT/\\\" #P\\\"$ROOT/src/runtime/sbcl.wasm\\\" :WASM32 :WASI\" $S/route.txt"
(cd tests && SBCL_WASM_TIMEOUT=900 sh -c '. ./subr.sh; run_sbcl --eval "(progn (print (list :subr *default-pathname-defaults*)) (terpri))" --quit') > $S/subr.txt 2>&1
check "tests/subr.sh's run_sbcl routes through the wrapper (cwd tests/)" "grep -q \"(:SUBR #P\\\"$ROOT/tests/\\\")\" $S/subr.txt"

echo "== run-program through the host"
ev '(print (list (sb-ext:process-exit-code (sb-ext:run-program "/bin/sh" (list "-c" "exit 3"))) (with-output-to-string (s) (sb-ext:run-program "/bin/sh" (list "-c" "echo out; echo err >&2") :output s :error :output)) (with-output-to-string (s) (with-input-from-string (in (format nil "x~%")) (sb-ext:run-program "/bin/cat" nil :input in :output s))) (sb-ext:process-exit-code (sb-ext:run-program sb-ext:*runtime-pathname* (list "--core" sb-int:*core-string* "--noinform" "--no-sysinit" "--no-userinit" "--eval" "(sb-ext:exit :code 7)") :output nil))))' > $S/run-program.txt 2>&1
check "run-program: exit codes, captured and merged output, stream input, a child runtime" "grep -q '^(3 \"out' $S/run-program.txt && grep -q 'err' $S/run-program.txt && grep -q ' 7)' $S/run-program.txt"
ev '(progn (test-util::setenv "UAT_VAR" "yes") (print (with-output-to-string (s) (sb-ext:run-program "/bin/sh" (list "-c" "echo $UAT_VAR") :output s))))' > $S/run-program-env.txt 2>&1 || true
SBCL_WASM_TIMEOUT=900 ./run-sbcl.sh $WARM --eval '(progn (sb-alien:alien-funcall (sb-alien:extern-alien "setenv" (function sb-alien:int sb-alien:c-string sb-alien:c-string sb-alien:int)) "UAT_VAR" "yes" 1) (print (with-output-to-string (s) (sb-ext:run-program "/bin/sh" (list "-c" "echo $UAT_VAR") :output s))))' > $S/run-program-env.txt 2>&1
check "the child gets the runtime's environment (setenv from Lisp)" "grep -q '\"yes' $S/run-program-env.txt"

echo "== compile-file, load, disassemble"
mkdir -p obj/wasm-build
ev '(progn (with-open-file (s "obj/wasm-build/uat9.lisp" :direction :output :if-exists :supersede) (write (quote (defun uat9-f (n) (if (< n 2) n (+ (uat9-f (- n 1)) (uat9-f (- n 2)))))) :stream s)) (compile-file "obj/wasm-build/uat9.lisp") (load "obj/wasm-build/uat9.fasl") (print (uat9-f 15)) (disassemble (quote uat9-f)) (disassemble (quote car)))' > $S/disassemble.txt 2>&1
check "compile-file and load; disassemble prints the Wasm of a loaded and of a core function" "grep -q '^610' $S/disassemble.txt && grep -q 'disassembly for UAT9-F' $S/disassemble.txt && grep -q 'the run-time module at' $S/disassemble.txt && grep -q 'the core module' $S/disassemble.txt && grep -q 'i32.load' $S/disassemble.txt && grep -q ' call ' $S/disassemble.txt"

echo "== contribs"
if [ "${UAT_FAST:-0}" != 1 ] || [ ! -f obj/sbcl-home/contrib/sb-md5.fasl ]; then
  check "the pure-Lisp contribs build (build-wasm.sh contrib)" "./build-wasm.sh contrib > $S/contrib.log 2>&1"
fi
for c in asdf sb-rt sb-md5 sb-cltl2 sb-rotate-byte sb-aclrepl sb-executable sb-queue sb-concurrency sb-introspect; do
  check "contrib $c built" "ls obj/sbcl-home/contrib/$c.fasl"
done
SBCL_WASM_TIMEOUT=900 ./run-sbcl.sh $WARM --eval '(require :sb-md5)' --eval '(print (sb-md5:md5sum-string "abc"))' > $S/md5.txt 2>&1
check "(require :sb-md5) and md5sum-string" "grep -q '#(144 1 80 152 60 210 79 176 214 150 63 125 40 225 127 114)' $S/md5.txt"
SBCL_WASM_TIMEOUT=900 ./run-sbcl.sh $WARM --eval '(require :asdf)' --eval '(print (asdf:asdf-version))' > $S/asdf.txt 2>&1
check "(require :asdf)" "grep -q '^\"3\\.' $S/asdf.txt"

echo "== the regression suite and the baseline"
if [ "${UAT_SKIP_SUITES:-0}" != 1 ]; then
  check "tests/run-tests.sh across all files (wasm-parallel-exec.sh) runs to completion" "(cd tests && sh ./wasm-parallel-exec.sh -j 4 > ../$S/regress.log 2>&1); grep -q '^==== Summary' $S/regress.log"
  check "tests/ansi-tests.sh runs to completion (one test at a time, restarted after a trap)" "(cd tests && sh ./ansi-tests.sh > ../$S/ansi.log 2>&1); grep -q '^tests: ' $S/ansi.log && [ \"\$(cat tests/ansi-test/progress.txt)\" = DONE ]"
  check "the baseline report is written" "mkdir -p doc/wasm-port/baselines && sh $S/baseline.sh $S/regress.log tests/ansi-test/results.txt > doc/wasm-port/baselines/sprint-8.txt && grep -q 'files:' doc/wasm-port/baselines/sprint-8.txt"
else
  check "the regression run completed (suites skipped: $S/regress.log)" "grep -q '^==== Summary' $S/regress.log"
  check "the ANSI run completed (suites skipped: $S/ansi.log)" "grep -q '^tests: ' $S/ansi.log && [ \"\$(cat tests/ansi-test/progress.txt)\" = DONE ]"
fi
check "the baseline report lists the files, the failing tests and the ANSI results" "grep -q '^files: ' doc/wasm-port/baselines/sprint-8.txt && grep -q '^== unexpected failures' doc/wasm-port/baselines/sprint-8.txt && grep -q '^== the ANSI suite' doc/wasm-port/baselines/sprint-8.txt"

echo "== regressions (Sprint 8)"
ev '(print (+ 1 2))' > $S/eval.txt 2>&1
check "--eval '(print (+ 1 2))' prints 3" "grep -q '^3 *$' $S/eval.txt"
ev '(progn (defclass uat-c () ((a :initarg :a :accessor uat-a))) (print (uat-a (make-instance (quote uat-c) :a 21))))' > $S/clos.txt 2>&1
check "CLOS in the saved core" "grep -q '^21' $S/clos.txt"
echo "== regressions (levels 0 and 1)"
if tests/wasm/run-level0.sh > $S/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' $S/level0.log) checks"; else bad "level-0 (see $S/level0.log)"; fi
if [ "${UAT_FAST:-0}" != 1 ] || [ ! -f obj/xbuild/wasm/after-xc.core ]; then
  check "after-xc core for the level-1 suite" "Sprints/Sprint5/after-xc.sh > $S/after-xc.log 2>&1 && ls obj/xbuild/wasm/after-xc.core"
fi
if XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > $S/level1.log 2>&1; then ok "level-1: $(grep '^level1:' $S/level1.log)"; else bad "level-1 (see $S/level1.log)"; fi

echo
echo "passed=$pass failed=$fail"
[ $fail = 0 ]
