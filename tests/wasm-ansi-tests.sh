#!/bin/sh
# The ANSI suite (tests/ansi-test) on the WebAssembly port. ansi-tests.sh
# loads the suite and runs every test in one process; here a trap in one
# test would end the run, so the suite is loaded once into a saved core
# (tests/ansi-test/wasm-ansi.core) and the tests run one at a time
# through tests/wasm-ansi-driver.lisp, each result recorded before the
# next starts; the process is restarted after a crash and resumes from
# the next test (a crashed test is retried once). Usage:
#   tests/wasm-ansi-tests.sh          (from anywhere; about two hours)
# Files in tests/ansi-test: wasm-ansi.core, results.txt (NAME PASS|FAIL|CRASHED),
# progress.txt, wasm-ansi.log; the summary is printed at the end.
# SBCL_WASM_ANSI_TIMEOUT (seconds, default 1800) bounds one process.
cd "$(dirname "$0")"
if [ ! -e ansi-test ]; then
   git clone --depth 1 https://github.com/sbcl/ansi-test.git
fi
cd ansi-test
rm -fr sandbox/scratch
# runtime options first (the runtime stops looking for them at the
# first toplevel option), then the toplevel options
RUNTIME_OPTIONS="--dynamic-space-size 1536MB --disable-ldb --lose-on-corruption"
LISP_OPTIONS="--noinform --no-userinit --no-sysinit --disable-debugger"
SBCL="../../tools-for-build/wasm-sbcl.sh"
if [ ! -f wasm-ansi.core ] || [ ../../output/sbcl.core -nt wasm-ansi.core ]; then
    echo "== loading the suite and saving wasm-ansi.core"
    # the suite's compile-and-load keeps fasls across runs: those of an
    # older build load into the new core and fail in odd ways
    find . -name '*.fasl' -delete
    SBCL_WASM_TIMEOUT=3600 $SBCL --core ../../output/sbcl.core $RUNTIME_OPTIONS $LISP_OPTIONS \
        --load gclload1.lsp --load gclload2.lsp --load ../wasm-ansi-driver.lisp \
        --eval '(in-package :cl-test)' \
        --eval '(disable-note :nil-vectors-are-strings)' \
        --eval '(sb-ext:save-lisp-and-die "wasm-ansi.core")' > wasm-ansi-load.log 2>&1 \
        || { tail -20 wasm-ansi-load.log; echo "loading the suite failed (see tests/ansi-test/wasm-ansi-load.log)"; exit 1; }
    cp ../../output/sbcl-core.wasm wasm-ansi-core.wasm
fi
rm -f results.txt progress.txt retry.txt wasm-ansi.log
here=$(pwd)
runs=0
echo "== running the tests one at a time (log: tests/ansi-test/wasm-ansi.log)"
while :; do
    runs=$((runs+1))
    SBCL_WASM_TIMEOUT=${SBCL_WASM_ANSI_TIMEOUT:-1800} $SBCL --core wasm-ansi.core $RUNTIME_OPTIONS $LISP_OPTIONS \
        --eval "(setf *default-pathname-defaults* (truename #P\"$here/sandbox/\"))" \
        --eval "(cl-test::wasm-run-tests \"$here/results.txt\" \"$here/progress.txt\" \"$here/retry.txt\")" >> wasm-ansi.log 2>&1
    status=$?
    if [ "$(cat progress.txt 2>/dev/null)" = DONE ]; then break; fi
    echo "process $runs ended with status $status at test $(cat progress.txt 2>/dev/null) ($(wc -l < results.txt) results so far)"
    if [ $runs -ge 300 ]; then echo "giving up after $runs processes"; break; fi
done
echo "== summary ($runs processes)"
echo "tests: $(wc -l < results.txt)  pass: $(grep -c ' PASS$' results.txt)  fail: $(grep -c ' FAIL$' results.txt)  crashed: $(grep -c ' CRASHED$' results.txt)"
echo "== failures"
grep ' FAIL$' results.txt | sed 's/ FAIL$//' | tr '\n' ' '; echo
echo "== crashed (a trap or the process deadline)"
grep ' CRASHED$' results.txt | sed 's/ CRASHED$//' | tr '\n' ' '; echo
# The expected failures: the one list in ansi-tests.sh (its #+wasm entries
# included), extracted from the --eval text and compared with the results
# in the saved core, the way ansi-tests.sh does at the end of its run.
echo "== against the expected failures of ansi-tests.sh"
awk '/\(expected \(list\*/ { on = 1; sub(/.*\(expected /, "") }
     on { print; n = gsub(/\(/, "("); m = gsub(/\)/, ")"); depth += n - m; if (depth <= 0) exit }' \
    ../ansi-tests.sh > wasm-ansi-expected.lisp-expr
# (the extracted text ends with the parenthesis closing the EXPECTED binding)
{ echo '(let* ((expected'
  cat wasm-ansi-expected.lisp-expr
  cat <<'LISP'
       (failing (with-open-file (in "results.txt")
                  (loop for line = (read-line in nil) while line
                        for space = (position #\Space line)
                        unless (string= (subseq line (1+ space)) "PASS")
                          collect (subseq line 0 space))))
       (unexpected (set-difference failing expected :test #'equal))
       (passing (set-difference expected failing :test #'equal)))
  (format t "unexpected failures: ~D~{ ~A~}~%" (length unexpected) (sort unexpected #'string<))
  (format t "expected to fail but passing: ~D~{ ~A~}~%" (length passing) (sort passing #'string<))
  (sb-ext:exit :code (if unexpected 1 0)))
LISP
} > wasm-ansi-compare.lisp
SBCL_WASM_TIMEOUT=300 $SBCL --core wasm-ansi.core $RUNTIME_OPTIONS $LISP_OPTIONS --load wasm-ansi-compare.lisp
