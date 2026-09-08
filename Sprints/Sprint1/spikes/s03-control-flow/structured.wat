;; S0.3: benchmarks written with structured control flow (what a stackifier
;; would emit). Fixnum-style arithmetic on i32 with tag bits kept simple.
(module
  (memory (export "memory") 1)
  ;; fib(n) recursive
  (func $fib (export "fib") (param $n i32) (result i32)
    (if (result i32) (i32.lt_s (local.get $n) (i32.const 2))
      (then (local.get $n))
      (else (i32.add (call $fib (i32.sub (local.get $n) (i32.const 1)))
                     (call $fib (i32.sub (local.get $n) (i32.const 2)))))))
  ;; tak
  (func $tak (export "tak") (param $x i32) (param $y i32) (param $z i32) (result i32)
    (if (result i32) (i32.eqz (i32.lt_s (local.get $y) (local.get $x)))
      (then (local.get $z))
      (else (call $tak
              (call $tak (i32.sub (local.get $x) (i32.const 1)) (local.get $y) (local.get $z))
              (call $tak (i32.sub (local.get $y) (i32.const 1)) (local.get $z) (local.get $x))
              (call $tak (i32.sub (local.get $z) (i32.const 1)) (local.get $x) (local.get $y))))))
  ;; tight loop: sum of i*i mod 7 for i below n, two nested branches per iteration
  (func $loop (export "loop") (param $n i32) (result i32)
    (local $i i32) (local $acc i32) (local $t i32)
    (block $exit
      (loop $top
        (br_if $exit (i32.ge_u (local.get $i) (local.get $n)))
        (local.set $t (i32.rem_u (i32.mul (local.get $i) (local.get $i)) (i32.const 7)))
        (if (i32.and (local.get $t) (i32.const 1))
          (then (local.set $acc (i32.add (local.get $acc) (local.get $t))))
          (else (local.set $acc (i32.sub (local.get $acc) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $top)))
    (local.get $acc))
  ;; memory scan: count bytes equal to 42 in [0, n)
  (func $scan (export "scan") (param $n i32) (result i32)
    (local $i i32) (local $c i32)
    (block $exit
      (loop $top
        (br_if $exit (i32.ge_u (local.get $i) (local.get $n)))
        (if (i32.eq (i32.load8_u (local.get $i)) (i32.const 42))
          (then (local.set $c (i32.add (local.get $c) (i32.const 1)))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $top)))
    (local.get $c))
  (func (export "fill") (param $n i32)
    (local $i i32)
    (block $exit (loop $top
      (br_if $exit (i32.ge_u (local.get $i) (local.get $n)))
      (i32.store8 (local.get $i) (i32.rem_u (local.get $i) (i32.const 50)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $top)))))
