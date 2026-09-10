#!/bin/sh
# cl-bench under the WebAssembly port: run cl-bench-driver.lisp with two
# cores (the same runtime, src/runtime/sbcl.wasm) and compare the times
# benchmark by benchmark, with the geometric mean of the ratios.
#   tests/wasm/bench/cl-bench-compare.sh <core-a> <core-b> <scale> [names...]
# The runs' logs go to obj/wasm-build/cl-bench/{a,b}.log; the fasls the
# driver compiles with each core to obj/wasm-build/cl-bench/{a,b}-fasl/.
# An argument ending in .results is a previous run's result file
# (obj/wasm-build/cl-bench/a.results, copied) used instead of a run.
# CL_BENCH_DIR names the cl-bench checkout (default /home/user/tools/cl-bench);
# CL_BENCH_HEAP the dynamic space (default 1GB: string-concat's 36 MB
# requests exhaust the 512 MB default when they land between the
# collection trigger and the next safe point).
# A benchmark that fails or is skipped in either run is listed and left
# out of the mean.
set -e
here=$(cd "$(dirname "$0")/../../.." && pwd)
core_a=$1; core_b=$2; scale=${3:-1}; shift 3 2>/dev/null || shift $#
bench_dir=${CL_BENCH_DIR:-/home/user/tools/cl-bench}
out=$here/obj/wasm-build/cl-bench
mkdir -p "$out"
run() { # tag core names...
    tag=$1; core=$2; shift 2
    case "$core" in
        *.results) cp "$core" "$out/$tag.results"; return ;;
    esac
    rm -rf "$out/$tag-fasl"
    "$here/tools-for-build/wasm-sbcl.sh" --core "$core" --dynamic-space-size "${CL_BENCH_HEAP:-1GB}" \
        --script "$here/tests/wasm/bench/cl-bench-driver.lisp" \
        "$bench_dir" "$out/$tag-fasl" "$scale" "$@" > "$out/$tag.log" 2>&1 || true
    grep -a "^RESULT\|^COMPILE" "$out/$tag.log" > "$out/$tag.results" || true
}
run a "$core_a" "$@"
run b "$core_b" "$@"
awk -v A="$core_a" -v B="$core_b" '
    FNR == 1 { file++ }
    $1 == "COMPILE" { compile[file] += $3; next }
    $1 == "RESULT" { name[$2] = 1; if ($3 == "SKIP") skip[file, $2] = 1; else { runs[file, $2] = $3; secs[file, $2] = $4 } }
    END {
        printf "%-24s %10s %10s %8s\n", "benchmark", "a (s)", "b (s)", "a/b"
        n = 0; logsum = 0
        for (b in name) {
            if (skip[1, b] || skip[2, b]) { printf "%-24s %10s %10s %8s\n", b, (skip[1, b] ? "skip" : secs[1, b]), (skip[2, b] ? "skip" : secs[2, b]), "-"; continue }
            if (runs[1, b] != runs[2, b]) { printf "%-24s runs differ (%s, %s)\n", b, runs[1, b], runs[2, b]; continue }
            if (secs[2, b] <= 0 || secs[1, b] <= 0) { printf "%-24s %10s %10s %8s\n", b, secs[1, b], secs[2, b], "-"; continue }
            r = secs[1, b] / secs[2, b]
            printf "%-24s %10.3f %10.3f %8.2f\n", b, secs[1, b], secs[2, b], r
            n++; logsum += log(r)
        }
        if (n > 0) printf "geometric mean of a/b over %d benchmarks: %.2f\n", n, exp(logsum / n)
        printf "compile time of the benchmark files: a %.1f s, b %.1f s\n", compile[1], compile[2]
    }' "$out/a.results" "$out/b.results"
