# cl-bench under the WebAssembly port: Sprint 13 (the register cache and the parameters)

Date: 2026-09-10. Machine: the development container (4 cores, x86-64
Linux), idle during the runs quoted here. Runtime: `src/runtime/sbcl.wasm`
of the Sprint 13 build under the Wasmtime host (`wasm/target/release/sbcl-wasm`).
Cores (`obj/wasm-build/`): `sbcl-s12opt.core` — Sprint 12's build (the
stackifier, `wasm-opt`); `sbcl-s13a.core` — the register cache, every
flush point moving the whole used set; `sbcl-s13b.core` — the flush and
reload sets of a full call and a return tuned; `sbcl-s13c.core` —
inline allocation; `sbcl-s13f.core` — NARGS and A0..A3 as the parameters
of the Lisp function type (the sprint's code; `sbcl-s13g.core` is the
same code with the collector's root fix and the save fix). The host
reference: SBCL 2.4.8 x86-64 on the same machine.

Driver: `tests/wasm/bench/cl-bench-driver.lisp` (cl-bench 20160513 at
`/home/user/tools/cl-bench`, its files compiled by each core);
`tests/wasm/bench/cl-bench-compare.sh` prints the tables. Sections 1–3:
every benchmark's run count divided by 10 (at least one run), one
measurement each, a 600 s limit per benchmark (none reached it), a
1 GB heap for the port (`CL_BENCH_HEAP`: the string benchmarks ask for
tens of megabytes between two safe points). Section 4: the original
run counts. Times are seconds of real time; `walk-list/mess` is
disabled for SBCL by cl-bench itself; `mandelbrot/dfloat` runs under a
millisecond at scale 10 and is left out of the means there.

## 1. The steps of the sprint against Sprint 12's core

Geometric means of Sprint 12's time over the build's, 62–63
benchmarks (`s12opt-vs-s13X.txt`); the s13a–s13c runs were taken with
a build running on the other cores, the s13f run on an idle machine
(`s13c-vs-s13f.txt`, both idle: 0.98).

| Build | Mean | `fib` | `tak` | `ctak` | `crc40` | `boyer` | `deriv` | `3d-arrays` | `mrg32k3a` | `clos-defmethod` |
|---|---|---|---|---|---|---|---|---|---|---|
| s13a: the cache | 1.27 | 1.19 | 1.07 | 0.99 | 1.25 | 1.42 | 0.82 | 3.60 | 3.13 | 0.62 |
| s13b: the masks | 1.35 | 1.13 | 1.02 | 0.97 | 1.35 | 1.42 | 0.93 | 4.07 | 2.67 | 0.61 |
| s13c: inline allocation | 1.49 | 1.09 | 1.22 | 0.98 | 1.43 | 1.61 | 1.56 | 3.84 | 3.43 | 0.58 |
| s13f: the parameters | 1.47 | 1.02 | 1.02 | 0.91 | 1.42 | 1.95 | 1.56 | 3.74 | 3.43 | 0.60 |
| s13h: the final core (the root and save fixes) | 1.43 | | | | | | | | | |

The s13h row (`s12opt-vs-s13h.txt`, `host-vs-s13h.txt`: 0.17 against
the host as well) is the code of s13f with the runtime validating the
register area's words as ambiguous roots; the difference is within the
run-to-run spread of the kernels that take a few milliseconds.

## 2. Sprint 12 (a) against the sprint's code (b), scale 10

```
benchmark                     a (s)      b (s)      a/b
takl                          0.112      0.108     1.04
ackermann                     9.881      9.636     1.03
destructive                   0.039      0.039     1.00
bitvectors                    0.298      0.114     2.61
compiler                      1.755      1.594     1.10
crc40                        15.086     10.651     1.42
triangle                      0.240      0.174     1.38
ctak                          0.422      0.464     0.91
3d-arrays                     1.541      0.412     3.74
fib-ratio                     0.003      0.002     1.50
factorial                     0.021      0.013     1.62
deflate-file                  0.061      0.054     1.13
clos-defclass                 1.067      1.598     0.67
richards                      0.236      0.204     1.16
puzzle                        0.194      0.209     0.93
bignum/elem-10000-1           0.332      0.127     2.61
mrg32k3a                      0.072      0.021     3.43
walk-list/seq                 0.040      0.020     2.00
eql-specialized-fib           0.458      0.401     1.14
search-sequence               1.204      0.948     1.27
fprint/pretty                 0.379      0.254     1.49
hash-strings                  0.166      0.097     1.71
div2-test-2                   0.085      0.058     1.47
mandelbrot/complex            0.056      0.028     2.00
pi-decimal/big                0.392      0.143     2.74
trtak                         0.043      0.044     0.98
boyer                         0.129      0.066     1.95
deriv                         0.028      0.018     1.56
pi-decimal/small              0.125      0.062     2.02
methodcalls                  12.194      8.578     1.42
clos-instantiate              0.034      0.039     0.87
methodcalls/complex           2.341      2.072     1.13
frpoly/bignum                 0.052      0.034     1.53
traverse                      0.103      0.078     1.32
fft                           0.002      0.002     1.00
bignum/elem-1000-100          0.417      0.174     2.40
load-fasl                     1.436      1.490     0.96
fill-strings/adjust          10.596      7.844     1.35
walk-list/mess                 skip       skip        -
slurp-lines                   0.002      0.002     1.00
clos-defmethod                3.671      6.134     0.60
boehm-gc                      2.045      1.654     1.24
browse                        0.071      0.033     2.15
2d-arrays                     0.582      0.172     3.38
bench-strings                 5.590      4.285     1.30
fprint/ugly                   0.219      0.163     1.34
sum-permutations              0.333      0.233     1.43
bignum/elem-100-1000          0.275      0.107     2.57
dderiv                        0.034      0.021     1.62
bignum/pari-200-5             0.103      0.051     2.02
bignum/pari-100-10            0.040      0.021     1.90
mandelbrot/dfloat             0.001      0.000        -
fib                           0.095      0.093     1.02
stak                          0.053      0.045     1.18
frpoly/float                  0.094      0.076     1.24
hash-integers                 0.037      0.019     1.95
pi-atan                       0.068      0.028     2.43
tak                           0.045      0.044     1.02
methodcalls+after             1.425      1.533     0.93
1d-arrays                     0.112      0.090     1.24
pi-ratios                     1.637      0.816     2.01
frpoly/fixnum                 0.101      0.083     1.22
string-concat                52.556     33.973     1.55
div2-test-1                   0.037      0.010     3.70
geometric mean of a/b over 62 benchmarks: 1.47
compile time of the benchmark files: a 5.4 s, b 5.4 s
```

The two losses are `clos-defmethod` and `clos-defclass`: methods
compiled at run time are modules the engine compiles, and the cached
code is a third bigger.

## 3. The host SBCL (a) against the sprint's code (b), scale 10: the slowdown

```
benchmark                     a (s)      b (s)      a/b
takl                          0.012      0.108     0.11
ackermann                     0.736      9.636     0.08
destructive                   0.008      0.039     0.21
bitvectors                    0.040      0.114     0.35
compiler                      0.212      1.594     0.13
crc40                         0.136     10.651     0.01
triangle                      0.036      0.174     0.21
ctak                          0.004      0.464     0.01
3d-arrays                     0.336      0.412     0.82
fib-ratio                     0.000      0.002        -
factorial                     0.008      0.013     0.62
deflate-file                  0.004      0.054     0.07
clos-defclass                 0.080      1.598     0.05
richards                      0.032      0.204     0.16
puzzle                        0.020      0.209     0.10
bignum/elem-10000-1           0.016      0.127     0.13
mrg32k3a                      0.016      0.021     0.76
walk-list/seq                 0.016      0.020     0.80
eql-specialized-fib           0.020      0.401     0.05
search-sequence               0.192      0.948     0.20
fprint/pretty                 0.028      0.254     0.11
hash-strings                  0.020      0.097     0.21
div2-test-2                   0.032      0.058     0.55
mandelbrot/complex            0.012      0.028     0.43
pi-decimal/big                0.036      0.143     0.25
trtak                         0.004      0.044     0.09
boyer                         0.012      0.066     0.18
deriv                         0.012      0.018     0.67
pi-decimal/small              0.016      0.062     0.26
methodcalls                   1.256      8.578     0.15
clos-instantiate              0.008      0.039     0.21
methodcalls/complex           0.184      2.072     0.09
frpoly/bignum                 0.008      0.034     0.24
traverse                      0.020      0.078     0.26
fft                           0.000      0.002        -
bignum/elem-1000-100          0.032      0.174     0.18
load-fasl                     0.004      1.490     0.00
fill-strings/adjust           0.852      7.844     0.11
walk-list/mess                 skip       skip        -
slurp-lines                   0.000      0.002        -
clos-defmethod                0.436      6.134     0.07
boehm-gc                      0.276      1.654     0.17
browse                        0.004      0.033     0.12
2d-arrays                     0.136      0.172     0.79
bench-strings                 0.516      4.285     0.12
fprint/ugly                   0.016      0.163     0.10
sum-permutations              0.052      0.233     0.22
bignum/elem-100-1000          0.016      0.107     0.15
dderiv                        0.012      0.021     0.57
bignum/pari-200-5             0.012      0.051     0.24
bignum/pari-100-10            0.004      0.021     0.19
mandelbrot/dfloat             0.004      0.000        -
fib                           0.004      0.093     0.04
stak                          0.012      0.045     0.27
frpoly/float                  0.016      0.076     0.21
hash-integers                 0.004      0.019     0.21
pi-atan                       0.016      0.028     0.57
tak                           0.008      0.044     0.18
methodcalls+after             0.120      1.533     0.08
1d-arrays                     0.012      0.090     0.13
pi-ratios                     0.204      0.816     0.25
frpoly/fixnum                 0.008      0.083     0.10
string-concat                 7.572     33.973     0.22
div2-test-1                   0.024      0.010     2.40
geometric mean of a/b over 59 benchmarks: 0.17
compile time of the benchmark files: a 0.6 s, b 5.4 s
```

The geometric mean of 0.17 is the port 5.9× slower than the host on
the whole suite (Sprint 12: 8.2×). The host's times at this scale are
a few milliseconds for many kernels, at the timer's resolution;
section 4 is the measurement.

## 4. The compute-bound subset at scale 1: the plan's exit criterion

The 31 kernels without allocation-heavy or I/O work (the Gabriel
kernels, the array, float and bignum loops), at the original run
counts, the host (a) against the sprint's code (b) with the fixed
runtime (`host-vs-s13f-compute-1.txt`; the same run found the
collector's root bug before the fix, `Sprints/Sprint13/develop.md`,
section 5):

```
benchmark                     a (s)      b (s)      a/b
takl                          0.148      0.961     0.15
ackermann                     0.740     10.017     0.07
destructive                   0.076      0.418     0.18
bitvectors                    0.104      0.348     0.30
crc40                         0.272     21.884     0.01
triangle                      0.200      0.760     0.26
ctak                          0.032      4.430     0.01
3d-arrays                     0.356      0.389     0.92
factorial                     0.052      0.139     0.37
richards                      0.152      0.873     0.17
puzzle                        0.232      2.039     0.11
mrg32k3a                      0.160      0.213     0.75
eql-specialized-fib           0.084      1.787     0.05
div2-test-2                   0.196      0.637     0.31
mandelbrot/complex            0.092      0.310     0.30
trtak                         0.048      0.387     0.12
boyer                         0.112      0.834     0.13
deriv                         0.080      0.203     0.39
fft                           0.008      0.014     0.57
browse                        0.064      0.358     0.18
2d-arrays                     0.256      0.337     0.76
dderiv                        0.076      0.242     0.31
mandelbrot/dfloat             0.004      0.004     1.00
fib                           0.052      0.789     0.07
stak                          0.112      0.401     0.28
frpoly/float                  0.120      0.809     0.15
pi-atan                       0.120      0.394     0.30
tak                           0.048      0.431     0.11
1d-arrays                     0.044      0.352     0.12
frpoly/fixnum                 0.084      0.825     0.10
div2-test-1                   0.132      0.150     0.88
geometric mean of a/b over 31 benchmarks: 0.19
compile time of the benchmark files: a 0.7 s, b 5.2 s
```

The geometric mean of 0.19 is 5.3× slower than the host. Within the
plan's 3×: `3d-arrays` (1.1×), `mandelbrot/dfloat` (1.0), `div2-test-1`
(1.1), `mrg32k3a` (1.3), `2d-arrays` (1.3), `fft` (1.8), `deriv` (2.5),
`factorial` (2.7) — eight kernels, the loops over arrays and floats.
Between 3× and 4×: `bitvectors`, `dderiv`, `div2-test-2`,
`mandelbrot/complex`, `pi-atan`, `stak`, `triangle` — seven. The
sixteen others are the call-heavy kernels at 5–25× (`tak` 9, `takl`
6.5, `fib` 15, `ackermann` 13.5, `eql-specialized-fib` 21, `puzzle`
9, `boyer` 7.5, the `frpoly` three 7–10, `1d-arrays` 8: a call per
element), and the two through the runtime: `ctak` at 138×
(`catch`/`throw` through the unwind routine and the engine's
exception) and `crc40` at 80× (`(unsigned-byte 40)` arithmetic is
bignum arithmetic on a 32-bit word). Not measured under V8: the port
has no JavaScript host (`SBCL-Handoff.md`). What a call costs and the
steps that cut it are in `Sprints/Sprint13/develop.md`, section 4.
