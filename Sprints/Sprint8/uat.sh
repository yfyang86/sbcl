#!/bin/sh
# Sprint 8 user-acceptance test. Exit criteria from doc/wasm-port/04-sprints.md
# (plan Sprint 7, "garbage collector and warm load"):
#   - gencgc on the target: (gc), (gc :full t), the automatic trigger,
#     allocation stress, with the heap verifier clean
#   - save-lisp-and-die through WASI; the saved core restarts to the REPL
#   - the warm load produces output/sbcl.core
#   - tests/gc-smoketest.pure.lisp and tests/coreparse.pure.lisp pass
#   - nothing regressed: level 0, level 1, the Sprint 7 checks
# UAT_FAST=1 skips the Lisp builds (about twenty minutes) and checks their
# products; UAT_SKIP_WARM=1 skips the warm load (about an hour) and uses
# the existing output/sbcl.core.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
S=Sprints/Sprint8
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
. tools-for-build/wasm-env.sh
RUN=tools-for-build/wasm_run.sh
COLD="src/runtime/sbcl.wasm --core obj/xbuild/wasm.core --noinform --no-sysinit --no-userinit --non-interactive"
ev() { SBCL_WASM_TIMEOUT=${T:-900} $RUN $COLD --eval "$1"; }

echo "== toolchain"
check "wasi-sdk present" "test -x $WASI_SDK/bin/clang"
check "host builds (sbcl-wasm)" "./build-wasm.sh host > $S/host.log 2>&1 && ls wasm/target/release/sbcl-wasm"

echo "== Lisp side"
if [ "${UAT_FAST:-0}" = 1 ]; then
  check "pass-2 products present (fast mode)" "ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm obj/xbuild/wasm-core.wasm.symbols obj/xbuild/wasm.map"
else
  check "build-wasm.sh lisp: pass-1 and pass-2 (xc.core, wasm.core, the core module)" \
    "rm -rf obj/xbuild/wasm/from-host obj/xbuild/wasm/from-xc obj/xbuild/wasm/xc.core obj/xbuild/wasm.core && ./build-wasm.sh --jobs 4 lisp > $S/lisp.log 2>&1 && ls obj/xbuild/wasm.core obj/xbuild/wasm-core.wasm"
fi
check "the core module validates (wasm-tools, all features)" "wasm-tools validate --features all obj/xbuild/wasm-core.wasm"

echo "== runtime"
if ./build-wasm.sh runtime > $S/build-runtime.log 2>&1; then ok "runtime builds: src/runtime/sbcl.wasm"; else bad "runtime build (see $S/build-runtime.log)"; fi
check "runtime build has no warnings" "! grep -q 'warning:' $S/build-runtime.log"
check "sbcl.wasm validates" "wasm-tools validate --features all src/runtime/sbcl.wasm"
check "the linkage table was extended for code loaded at run time" "grep -q 'linkage table: .* more symbols' $S/build-runtime.log && grep -q '\"coalesce_similar_objects\"' src/runtime/wasm-linkage-table.c"
check "groveled constants are up to date" "tools-for-build/wasm-grovel-headers.sh $S/groveled.lisp > $S/grovel.log 2>&1 && diff -q $S/groveled.lisp crossbuild-runner/backends/wasm/stuff-groveled-from-headers.lisp && rm -f $S/groveled.lisp"

echo "== the garbage collector"
SBCL_WASM_VERIFY_GC=1 SBCL_WASM_TIMEOUT=900 $RUN $COLD --eval '(gc)' --eval '(print :gc)' --eval '(gc :full t)' --eval '(print :full)' > $S/gc-verify.txt 2>&1
check "(gc) and (gc :full t) return, the heap verifier clean before and after each" "grep -q ':FULL' $S/gc-verify.txt && ! grep -q 'Ptr .* sees\|not remembered\|Verify failed' $S/gc-verify.txt"
ev '(let ((keep (loop for i below 100000 collect (cons i i)))) (dotimes (j 30) (loop repeat 200000 collect (make-array 8))) (gc :full t) (format t "~%usage ~D ok=~A~%" (sb-kernel:dynamic-usage) (loop for c in keep for i from 0 always (and (= (car c) i) (= (cdr c) i)))))' > $S/gc-stress.txt 2>&1
check "allocation stress: 6 million vectors through the automatic trigger, live data intact" "grep -q 'ok=T' $S/gc-stress.txt"
ev '(let ((h (make-hash-table :test (quote eq))) (keys (loop for i below 2000 collect (list i)))) (loop for k in keys for i from 0 do (setf (gethash k h) i)) (dotimes (j 5) (loop repeat 100000 collect (make-array 4)) (gc)) (gc :full t) (print (loop for k in keys for i from 0 always (eql (gethash k h) i))))' > $S/gc-hash.txt 2>&1
check "an EQ hash table of 2000 keys survives five collections (rehash)" "grep -q '^T' $S/gc-hash.txt"
ev '(let* ((live (list 1)) (w1 (make-weak-pointer live)) (w2 (make-weak-pointer (list 2)))) (gc :full t) (print (list (weak-pointer-value w1) (weak-pointer-value w2))))' > $S/gc-weak.txt 2>&1
check "weak pointers: the live referent kept, the dead one broken" "grep -q '((1) NIL)' $S/gc-weak.txt"
ev '(progn (gc :full t) (eval (quote (defun uat-f (x) (* x 3)))) (print (uat-f 5)) (gc) (print (funcall (compile nil (quote (lambda (y) (uat-f y)))) 7)) (print (handler-case (car (read-from-string "3")) (error (e) (type-of e)))))' > $S/gc-after.txt 2>&1
check "defun, compile and an error after collections (the store barrier and the code written flag)" "grep -q '^15' $S/gc-after.txt && grep -q '^21' $S/gc-after.txt && grep -q 'TYPE-ERROR' $S/gc-after.txt"

echo "== foreign calls and files"
ev '(print (multiple-value-list (decode-universal-time 3900000000)))' > $S/alien64.txt 2>&1
check "a foreign call with a 64-bit integer (get_timezone's time_t) works" "grep -q '^(0 0 ' $S/alien64.txt"
mkdir -p obj/wasm-build
ev '(progn (with-open-file (s "obj/wasm-build/uat-cf.lisp" :direction :output :if-exists :supersede) (write (quote (defun uat-fib (n) (if (< n 2) n (+ (uat-fib (- n 1)) (uat-fib (- n 2)))))) :stream s) (terpri s) (write (quote (defvar *uat-x* (list :a :b))) :stream s)) (compile-file "obj/wasm-build/uat-cf.lisp") (load "obj/wasm-build/uat-cf.fasl") (print (list (uat-fib 15) *uat-x*)) (gc :full t) (print (uat-fib 16)))' > $S/compile-file.txt 2>&1
check "compile-file writes a fasl with the Wasm code; load instantiates it; the functions survive a GC" "grep -q '(610 (:A :B))' $S/compile-file.txt && grep -q '^987' $S/compile-file.txt"

echo "== the warm load and the saved core"
if [ "${UAT_SKIP_WARM:-0}" != 1 ]; then
  check "the warm load produces output/sbcl.core (tools-for-build/wasm-warm.sh)" "tools-for-build/wasm-warm.sh > $S/warm.log 2>&1 && ls output/sbcl.core output/sbcl-core.wasm"
else
  check "output/sbcl.core present (warm load skipped)" "ls output/sbcl.core output/sbcl-core.wasm"
fi
WARM="src/runtime/sbcl.wasm --core output/sbcl.core --noinform --no-sysinit --no-userinit --non-interactive"
SBCL_WASM_TIMEOUT=900 $RUN src/runtime/sbcl.wasm --core output/sbcl.core --no-sysinit --no-userinit --non-interactive --eval '(print (+ 1 2))' > $S/saved-core.txt 2>&1
check "the saved core restarts (its run-time modules instantiated again) and evaluates" "grep -q 'instantiating .* saved modules' $S/saved-core.txt && grep -q '^3 *$' $S/saved-core.txt"
SBCL_WASM_TIMEOUT=900 $RUN $WARM --eval '(print (list (find-class (quote standard-object)) (describe (quote car))))' > $S/saved-pcl.txt 2>&1
check "PCL and the warm functions are there (find-class, describe)" "grep -q 'STANDARD-CLASS COMMON-LISP:STANDARD-OBJECT' $S/saved-pcl.txt"
echo "(defun fib (n) (if (< n 2) n (+ (fib (- n 1)) (fib (- n 2))))) (print (fib 20)) (terpri)" | SBCL_WASM_TIMEOUT=900 $RUN src/runtime/sbcl.wasm --core output/sbcl.core --noinform --no-sysinit --no-userinit --disable-debugger > $S/saved-repl.txt 2>&1
check "the saved core's REPL reads stdin, compiles and calls (fib 20 = 6765)" "grep -q '6765' $S/saved-repl.txt"
SBCL_WASM_TIMEOUT=900 $RUN $WARM --eval '(progn (defclass uat-c () ((a :initarg :a :accessor uat-a))) (defmethod uat-m ((x uat-c)) (* 2 (uat-a x))) (print (list (uat-m (make-instance (quote uat-c) :a 21)) (funcall (compile nil (quote (lambda (x) (uat-a x)))) (make-instance (quote uat-c) :a 5)))))' > $S/saved-clos.txt 2>&1
check "CLOS in the saved core: defclass, defmethod, an accessor through compile" "grep -q '(42 5)' $S/saved-clos.txt"
SBCL_WASM_TIMEOUT=900 $RUN $WARM --eval '(print (list (eval (quote (sb-alien:alien-funcall (sb-alien:extern-alien "os_get_errno" (function sb-alien:int))))) (eval (quote (sb-alien:extern-alien "gencgc_verbose" sb-alien:int)))))' > $S/saved-alien.txt 2>&1
check "foreign calls and variables from the evaluator in the saved core (the run-time foreign-symbol lookup)" "grep -q '^([0-9]* [0-9]*)' $S/saved-alien.txt"
# one pure test file, the way tests/run-tests.lisp's pure-runner loads it: test-util
# (WITH-TEST) in a fresh package using TEST-UTIL, then the failures list
run_pure_test() {
  SBCL_WASM_TIMEOUT=1800 $RUN $WARM --load tests/test-util.lisp --eval "(let ((*package* (make-package \"TEST-$$\" :use (list \"CL\" \"SB-EXT\" \"TEST-UTIL\"))) (test-util::*elapsed-times* nil)) (load \"$1\") (format t \"~%failures: ~S~%\" test-util:*failures*) (sb-ext:exit :code (if test-util:*failures* 1 0)))"
}
run_pure_test tests/gc-smoketest.pure.lisp > $S/gc-smoketest.txt 2>&1
check "tests/gc-smoketest.pure.lisp passes (3 tests)" "grep -q 'failures: NIL' $S/gc-smoketest.txt && [ \$(grep -c '::: Success' $S/gc-smoketest.txt) -ge 3 ]"
run_pure_test tests/coreparse.pure.lisp > $S/coreparse-test.txt 2>&1
check "tests/coreparse.pure.lisp passes (its tests are for immobile space; the file loads)" "grep -q 'failures: NIL' $S/coreparse-test.txt"

echo "== regressions (Sprint 7)"
ev '(print (+ 1 2))' > $S/cold-eval.txt 2>&1
check "the cold core: --eval '(print (+ 1 2))' prints 3" "grep -q '^3 *$' $S/cold-eval.txt"
check "--version" "$RUN src/runtime/sbcl.wasm --version | grep -q '^SBCL '"
ev '(handler-case (car (read-from-string "3")) (error (e) (print (type-of e))))' > $S/error.txt 2>&1
check "an internal error enters the condition system" "grep -q 'TYPE-ERROR' $S/error.txt"

echo "== regressions (levels 0 and 1)"
if tests/wasm/run-level0.sh > $S/level0.log 2>&1; then ok "level-0: $(grep -c '^PASS' $S/level0.log) checks"; else bad "level-0 (see $S/level0.log)"; fi
if [ "${UAT_FAST:-0}" != 1 ] || [ ! -f obj/xbuild/wasm/after-xc.core ]; then
  check "after-xc core for the level-1 suite" "Sprints/Sprint5/after-xc.sh > $S/after-xc.log 2>&1 && ls obj/xbuild/wasm/after-xc.core"
fi
if XC_CORE=obj/xbuild/wasm/after-xc.core tests/wasm/run-level1.sh > $S/level1.log 2>&1; then
  ok "level-1: $(grep '^level1:' $S/level1.log)"
else
  bad "level-1 (see $S/level1.log)"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
