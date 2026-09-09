#!/bin/sh
# The baseline report of the regression suite on the WebAssembly port:
#   Sprints/Sprint9/baseline.sh REGRESS-LOG > doc/wasm-port/baselines/sprint-8.txt
# REGRESS-LOG is tests/wasm-parallel-exec.sh's output (its first line
# names the log directory); the report lists every file that did not
# complete and every test the runner reported as an unexpected failure,
# unexpected success or leftover thread, from the per-file logs.
log=$1
logdir=$(sed -n 's/^==== Writing logs to \(.*\) ====$/\1/p' "$log" | head -1)
[ -d "$logdir" ] || { echo "no log directory in $log" >&2; exit 1; }
cd "$(dirname "$0")/../.."
echo "SBCL WebAssembly port: regression suite baseline (plan Sprint 8; Sprints/Sprint9)"
echo "date: $(date -u +%Y-%m-%dT%H:%MZ)  commit: $(git rev-parse --short HEAD)  runtime: src/runtime/sbcl.wasm  core: output/sbcl.core"
echo "runner: tests/wasm-parallel-exec.sh (one sbcl-wasm per file through run-tests.sh; impure and shell tests in host processes)"
total=$(wc -l < "$logdir/results.txt")
failed=$(grep -cv "^0 " "$logdir/results.txt")
echo "files: $total  passed: $((total - failed))  failed or incomplete: $failed"
echo
echo "== files that did not pass (status, seconds, file; 104 is the runner's success code inside run-tests.sh)"
grep -v "^0 " "$logdir/results.txt" | sort -k3 | while read -r status secs file; do
    f="$logdir/$file.log"
    if grep -q "^Status:" "$f" 2>/dev/null; then how="reported"
    elif grep -q "wasm trap\|error while executing" "$f" 2>/dev/null; then how="trap: $(sed -n 's/^ *wasm trap: //p' "$f" | head -1)"
    elif grep -q "deadline\|SBCL_WASM_TIMEOUT" "$f" 2>/dev/null; then how="timeout"
    elif grep -q "Heap exhausted" "$f" 2>/dev/null; then how="heap exhausted"
    elif grep -q "fatal error" "$f" 2>/dev/null; then how="fatal: $(grep -A1 "fatal error" "$f" | tail -1 | cut -c1-80)"
    else how="no report"; fi
    echo "$status $secs $file  [$how]"
done
echo
echo "== unexpected failures (file / test)"
grep -h "^ Failure:" "$logdir"/*.log | sed 's/^ Failure: //' | sort -u
echo
echo "== unexpected successes"
grep -h "^ Unexpected success:" "$logdir"/*.log | sed 's/^ Unexpected success: //' | sort -u
echo
echo "== leftover threads, invalid exit status, unhandled errors"
grep -h "^ Leftover thread\|^ Invalid exit status:\|^Unhandled " "$logdir"/*.log | sort | uniq -c | sort -rn | head -50
echo
echo "== counts"
echo "unexpected failures: $(grep -h "^ Failure:" "$logdir"/*.log | sort -u | wc -l)"
echo "expected failures: $(grep -h "^ Expected failure:" "$logdir"/*.log | wc -l)"
echo "skipped (broken/irrelevant/unimplemented): $(grep -h "^ Skipped" "$logdir"/*.log | wc -l)"
echo "successes: $(grep -h "^::: Success" "$logdir"/*.log | wc -l)"
