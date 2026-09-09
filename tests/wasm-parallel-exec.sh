#!/bin/sh
# The parallel test runner for the WebAssembly port. parallel-exec.lisp
# forks a child per test file and execs the shell for the .sh tests,
# which WASI cannot do; here the host runs one sbcl-wasm per file
# through run-tests.sh (whose impure and shell tests run their children
# through the host's run_process import), N at a time, and summarizes
# the logs. Usage: tests/wasm-parallel-exec.sh [-j N] [run-tests.sh options] [files]
# Logs: $SBCL_PAREXEC_TMP/sbcl-test-logs-$$ (default under $HOME);
# the summary lists every file that did not end with the runner's
# success line, and every unexpected failure it reported.
cd "$(dirname "$0")"
jobs=4
case "$1" in -j) jobs=$2; shift 2 ;; -j*) jobs=${1#-j}; shift ;; esac
logdir=${SBCL_PAREXEC_TMP:-$HOME}/sbcl-test-logs-$$
mkdir -p "$logdir"
echo "==== Writing logs to $logdir ===="
opts=""
files=""
for arg in "$@"; do
    case "$arg" in
        --*) opts="$opts $arg" ;;
        *) files="$files $arg" ;;
    esac
done
if [ -z "$files" ]; then
    files=$(ls *.pure.lisp *.pure-cload.lisp *.impure.lisp *.impure-cload.lisp *.test.sh 2>/dev/null)
fi
export logdir opts
echo "$files" | tr ' ' '\n' | grep . | xargs -P "$jobs" -I{} sh -c '
    f={}; log="$logdir/$f.log"
    start=$(date +%s)
    SBCL_WASM_TIMEOUT=${SBCL_WASM_TEST_TIMEOUT:-1800} sh ./run-tests.sh $opts "$f" > "$log" 2>&1
    status=$?
    echo "$status $(( $(date +%s) - start ))s $f"
' | tee "$logdir/results.txt"
echo "==== Summary ===="
echo "files: $(wc -l < "$logdir/results.txt"), failed: $(grep -cv "^0 " "$logdir/results.txt")"
grep -v "^0 " "$logdir/results.txt" | sort -k3 > "$logdir/failed-files.txt"
[ -s "$logdir/failed-files.txt" ] && { echo "-- files whose run did not succeed (status, time, file):"; cat "$logdir/failed-files.txt"; }
# the runner's own report of unexpected failures, per file
for f in "$logdir"/*.log; do
    grep -h "^ *Failure\|^ *Unexpected\|^ *Unhandled\|^ *Invalid exit status\|^ *Crashed\|^ *Timed out\|Expected failure\|Skipped" "$f" 2>/dev/null | grep -v "Expected failure\|Skipped" | sed "s|^|$(basename "$f" .log): |"
done > "$logdir/failures.txt"
echo "unexpected failures: $(wc -l < "$logdir/failures.txt") (in $logdir/failures.txt)"
head -100 "$logdir/failures.txt"
