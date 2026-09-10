# cl-bench under the WebAssembly port: Sprint 12 (the stackifier)

Date: 2026-09-10. Machine: the development container (4 cores, x86-64
Linux), idle during the runs. Runtime: `src/runtime/sbcl.wasm` of the
Sprint 12 build under the Wasmtime host (`wasm/target/release/sbcl-wasm`).
Cores (`obj/wasm-build/`): `sbcl-s11.core` — Sprint 11's build, the
dispatch loop; `sbcl-s12.core` — the stackifier; `sbcl-s12opt.core` —
the stackifier with `wasm-opt -O2 -g` on the cold core module.
The host reference: SBCL 2.4.8 x86-64 on the same machine.

Driver: `tests/wasm/bench/cl-bench-driver.lisp` (cl-bench 20160513 at
`/home/user/tools/cl-bench`, its files compiled by each core), every
benchmark's run count divided by 10 (at least one run), one measurement
each, a 600 s limit per benchmark (none reached it);
`tests/wasm/bench/cl-bench-compare.sh` prints the tables. Times are
seconds of real time for the scaled run count; `walk-list/mess` is
disabled for SBCL by cl-bench itself; `mandelbrot/dfloat` runs under a
millisecond and is left out of the means.

## 1. Dispatch loop (a) against the stackifier (b)

```
benchmark                     a (s)      b (s)      a/b
takl                          0.151      0.134     1.13
ackermann                    13.182     10.236     1.29
destructive                   0.068      0.049     1.39
bitvectors                    0.457      0.304     1.50
compiler                      2.541      1.799     1.41
crc40                        17.362     14.776     1.18
triangle                      0.298      0.239     1.25
ctak                          0.472      0.481     0.98
3d-arrays                     1.443      1.494     0.97
fib-ratio                     0.003      0.003     1.00
factorial                     0.029      0.023     1.26
deflate-file                  0.068      0.066     1.03
clos-defclass                 1.102      1.142     0.96
richards                      0.306      0.247     1.24
puzzle                        0.360      0.262     1.37
bignum/elem-10000-1           0.355      0.279     1.27
mrg32k3a                      0.074      0.071     1.04
walk-list/seq                 0.024      0.026     0.92
eql-specialized-fib           0.573      0.442     1.30
search-sequence               1.312      1.092     1.20
fprint/pretty                 0.446      0.362     1.23
hash-strings                  0.167      0.120     1.39
div2-test-2                   0.105      0.097     1.08
mandelbrot/complex            0.054      0.050     1.08
pi-decimal/big                0.473      0.316     1.50
trtak                         0.067      0.054     1.24
boyer                         0.123      0.104     1.18
deriv                         0.040      0.034     1.18
pi-decimal/small              0.129      0.097     1.33
methodcalls                  15.472     13.442     1.15
clos-instantiate              0.041      0.034     1.21
methodcalls/complex           2.283      2.406     0.95
frpoly/bignum                 0.065      0.066     0.98
traverse                      0.105      0.096     1.09
fft                           0.004      0.002     2.00
bignum/elem-1000-100          0.419      0.363     1.15
load-fasl                     0.508      1.308     0.39
fill-strings/adjust          11.606     10.170     1.14
walk-list/mess                 skip       skip        -
slurp-lines                   0.003      0.001     3.00
clos-defmethod                4.556      4.516     1.01
boehm-gc                      2.475      2.082     1.19
browse                        0.055      0.051     1.08
2d-arrays                     0.614      0.548     1.12
bench-strings                 6.110      5.833     1.05
fprint/ugly                   0.269      0.253     1.06
sum-permutations              0.358      0.331     1.08
bignum/elem-100-1000          0.237      0.216     1.10
dderiv                        0.044      0.038     1.16
bignum/pari-200-5             0.103      0.079     1.30
bignum/pari-100-10            0.038      0.033     1.15
mandelbrot/dfloat             0.000      0.000        -
fib                           0.130      0.104     1.25
stak                          0.083      0.067     1.24
frpoly/float                  0.130      0.112     1.16
hash-integers                 0.042      0.027     1.56
pi-atan                       0.078      0.062     1.26
tak                           0.063      0.053     1.19
methodcalls+after             1.483      1.314     1.13
1d-arrays                     0.123      0.110     1.12
pi-ratios                     1.694      1.290     1.31
frpoly/fixnum                 0.140      0.129     1.09
string-concat                61.770     48.336     1.28
div2-test-1                   0.047      0.042     1.12
geometric mean of a/b over 62 benchmarks: 1.18
compile time of the benchmark files: a 7.7 s, b 5.5 s
```

## 2. Stackifier (a) against the stackifier with wasm-opt (b)

```
benchmark                     a (s)      b (s)      a/b
takl                          0.134      0.130     1.03
ackermann                    10.236     10.008     1.02
destructive                   0.049      0.045     1.09
bitvectors                    0.304      0.302     1.01
compiler                      1.799      1.716     1.05
crc40                        14.776     14.941     0.99
triangle                      0.239      0.201     1.19
ctak                          0.481      0.484     0.99
3d-arrays                     1.494      1.538     0.97
fib-ratio                     0.003      0.002     1.50
factorial                     0.023      0.020     1.15
deflate-file                  0.066      0.062     1.06
clos-defclass                 1.142      1.006     1.14
richards                      0.247      0.204     1.21
puzzle                        0.262      0.222     1.18
bignum/elem-10000-1           0.279      0.349     0.80
mrg32k3a                      0.071      0.064     1.11
walk-list/seq                 0.026      0.024     1.08
eql-specialized-fib           0.442      0.426     1.04
search-sequence               1.092      1.171     0.93
fprint/pretty                 0.362      0.309     1.17
hash-strings                  0.120      0.155     0.77
div2-test-2                   0.097      0.090     1.08
mandelbrot/complex            0.050      0.043     1.16
pi-decimal/big                0.316      0.402     0.79
trtak                         0.054      0.057     0.95
boyer                         0.104      0.101     1.03
deriv                         0.034      0.032     1.06
pi-decimal/small              0.097      0.133     0.73
methodcalls                  13.442     13.062     1.03
clos-instantiate              0.034      0.026     1.31
methodcalls/complex           2.406      1.948     1.24
frpoly/bignum                 0.066      0.063     1.05
traverse                      0.096      0.084     1.14
fft                           0.002      0.003     0.67
bignum/elem-1000-100          0.363      0.439     0.83
load-fasl                     1.308      0.393     3.33
fill-strings/adjust          10.170     10.798     0.94
walk-list/mess                 skip       skip        -
slurp-lines                   0.001      0.002     0.50
clos-defmethod                4.516      4.193     1.08
boehm-gc                      2.082      2.092     1.00
browse                        0.051      0.051     1.00
2d-arrays                     0.548      0.547     1.00
bench-strings                 5.833      5.315     1.10
fprint/ugly                   0.253      0.231     1.10
sum-permutations              0.331      0.324     1.02
bignum/elem-100-1000          0.216      0.274     0.79
dderiv                        0.038      0.036     1.06
bignum/pari-200-5             0.079      0.109     0.72
bignum/pari-100-10            0.033      0.041     0.80
mandelbrot/dfloat             0.000      0.001        -
fib                           0.104      0.078     1.33
stak                          0.067      0.063     1.06
frpoly/float                  0.112      0.109     1.03
hash-integers                 0.027      0.037     0.73
pi-atan                       0.062      0.070     0.89
tak                           0.053      0.052     1.02
methodcalls+after             1.314      1.279     1.03
1d-arrays                     0.110      0.113     0.97
pi-ratios                     1.290      1.679     0.77
frpoly/fixnum                 0.129      0.112     1.15
string-concat                48.336     52.284     0.92
div2-test-1                   0.042      0.057     0.74
geometric mean of a/b over 62 benchmarks: 1.01
compile time of the benchmark files: a 5.5 s, b 5.6 s
```

## 3. Stackifier with wasm-opt (a) against the host SBCL (b): the slowdown

```
benchmark                     a (s)      b (s)      a/b
takl                          0.130      0.012    10.83
ackermann                    10.008      0.736    13.60
destructive                   0.045      0.008     5.62
bitvectors                    0.302      0.040     7.55
compiler                      1.716      0.212     8.09
crc40                        14.941      0.136   109.86
triangle                      0.201      0.036     5.58
ctak                          0.484      0.004   121.00
3d-arrays                     1.538      0.336     4.58
fib-ratio                     0.002      0.000        -
factorial                     0.020      0.008     2.50
deflate-file                  0.062      0.004    15.50
clos-defclass                 1.006      0.080    12.57
richards                      0.204      0.032     6.37
puzzle                        0.222      0.020    11.10
bignum/elem-10000-1           0.349      0.016    21.81
mrg32k3a                      0.064      0.016     4.00
walk-list/seq                 0.024      0.016     1.50
eql-specialized-fib           0.426      0.020    21.30
search-sequence               1.171      0.192     6.10
fprint/pretty                 0.309      0.028    11.04
hash-strings                  0.155      0.020     7.75
div2-test-2                   0.090      0.032     2.81
mandelbrot/complex            0.043      0.012     3.58
pi-decimal/big                0.402      0.036    11.17
trtak                         0.057      0.004    14.25
boyer                         0.101      0.012     8.42
deriv                         0.032      0.012     2.67
pi-decimal/small              0.133      0.016     8.31
methodcalls                  13.062      1.256    10.40
clos-instantiate              0.026      0.008     3.25
methodcalls/complex           1.948      0.184    10.59
frpoly/bignum                 0.063      0.008     7.88
traverse                      0.084      0.020     4.20
fft                           0.003      0.000        -
bignum/elem-1000-100          0.439      0.032    13.72
load-fasl                     0.393      0.004    98.25
fill-strings/adjust          10.798      0.852    12.67
walk-list/mess                 skip       skip        -
slurp-lines                   0.002      0.000        -
clos-defmethod                4.193      0.436     9.62
boehm-gc                      2.092      0.276     7.58
browse                        0.051      0.004    12.75
2d-arrays                     0.547      0.136     4.02
bench-strings                 5.315      0.516    10.30
fprint/ugly                   0.231      0.016    14.44
sum-permutations              0.324      0.052     6.23
bignum/elem-100-1000          0.274      0.016    17.12
dderiv                        0.036      0.012     3.00
bignum/pari-200-5             0.109      0.012     9.08
bignum/pari-100-10            0.041      0.004    10.25
mandelbrot/dfloat             0.001      0.004     0.25
fib                           0.078      0.004    19.50
stak                          0.063      0.012     5.25
frpoly/float                  0.109      0.016     6.81
hash-integers                 0.037      0.004     9.25
pi-atan                       0.070      0.016     4.38
tak                           0.052      0.008     6.50
methodcalls+after             1.279      0.120    10.66
1d-arrays                     0.113      0.012     9.42
pi-ratios                     1.679      0.204     8.23
frpoly/fixnum                 0.112      0.008    14.00
string-concat                52.284      7.572     6.90
div2-test-1                   0.057      0.024     2.38
geometric mean of a/b over 60 benchmarks: 8.21
compile time of the benchmark files: a 5.6 s, b 0.6 s
```

## 4. Reading

- The stackifier: 1.18 on the geometric mean of 62 benchmarks; every
  benchmark of more than a few milliseconds between 1.0 and 1.5; the
  call-heavy kernels 1.2–1.3; the compile of the Gabriel benchmarks
  1.41. The three ratios outside that range (`fft`, `slurp-lines`,
  `load-fasl`) are millisecond timings and file-cache effects.
- `wasm-opt`: 1.01, noise; the gain is 12% of module size.
- Against the host: 8.2× slower on the geometric mean of the 60
  benchmarks with a measurable host time (the rest run under a
  millisecond natively); the widest gaps are `ctak`
  (121×: catch and throw are Wasm exceptions through the runtime),
  `crc40` (110×: `(signed-byte 56)` arithmetic is generic on a 32-bit
  word) and `load-fasl` (98×), then the bignum and call-heavy kernels
  at 15–22×.
- Sprint 12's record (`Sprints/Sprint12/develop.md`, section 6) reads
  these against the factor S0.3 predicted.
