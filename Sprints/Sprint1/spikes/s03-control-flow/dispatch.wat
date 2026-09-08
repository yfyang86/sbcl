;; S0.3: the same benchmarks in the "dispatch loop" encoding that the first
;; version of the SBCL wasm backend would emit: every IR2 basic block is an
;; arm of a br_table inside one loop; every taken branch sets $pc and
;; branches to the loop head; fall-through is free.
(module
  (memory (export "memory") 1)
  (func $fib (export "fib") (param $n i32) (result i32)
    (local $pc i32) (local $r i32)
    (loop $L
      (block $B2 (block $B1 (block $B0
        (br_table $B0 $B1 $B2 (local.get $pc)))
        ;; block 0: entry, test
        (if (i32.lt_s (local.get $n) (i32.const 2))
          (then (local.set $pc (i32.const 2)) (br $L)))
        (local.set $pc (i32.const 1)) (br $L))
        ;; block 1: recursive case
        (local.set $r (i32.add (call $fib (i32.sub (local.get $n) (i32.const 1)))
                               (call $fib (i32.sub (local.get $n) (i32.const 2)))))
        (return (local.get $r)))
      ;; block 2: base case
      (return (local.get $n)))
    (unreachable))
  (func $tak (export "tak") (param $x i32) (param $y i32) (param $z i32) (result i32)
    (local $pc i32) (local $r i32)
    (loop $L
      (block $B2 (block $B1 (block $B0
        (br_table $B0 $B1 $B2 (local.get $pc)))
        (if (i32.eqz (i32.lt_s (local.get $y) (local.get $x)))
          (then (local.set $pc (i32.const 2)) (br $L)))
        (local.set $pc (i32.const 1)) (br $L))
        (return (call $tak
              (call $tak (i32.sub (local.get $x) (i32.const 1)) (local.get $y) (local.get $z))
              (call $tak (i32.sub (local.get $y) (i32.const 1)) (local.get $z) (local.get $x))
              (call $tak (i32.sub (local.get $z) (i32.const 1)) (local.get $x) (local.get $y)))))
      (return (local.get $z)))
    (unreachable))
  (func $loop (export "loop") (param $n i32) (result i32)
    (local $pc i32) (local $i i32) (local $acc i32) (local $t i32)
    (loop $L
      (block $B4 (block $B3 (block $B2 (block $B1 (block $B0
        (br_table $B0 $B1 $B2 $B3 $B4 (local.get $pc)))
        ;; B0: loop head test
        (if (i32.ge_u (local.get $i) (local.get $n))
          (then (local.set $pc (i32.const 4)) (br $L)))
        (local.set $t (i32.rem_u (i32.mul (local.get $i) (local.get $i)) (i32.const 7)))
        (if (i32.and (local.get $t) (i32.const 1))
          (then (local.set $pc (i32.const 1)) (br $L)))
        (local.set $pc (i32.const 2)) (br $L))
        ;; B1: odd
        (local.set $acc (i32.add (local.get $acc) (local.get $t)))
        (local.set $pc (i32.const 3)) (br $L))
        ;; B2: even
        (local.set $acc (i32.sub (local.get $acc) (i32.const 1))))
        ;; B3: increment, back edge (fall-through from B2)
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $pc (i32.const 0)) (br $L))
      ;; B4: exit
      (return (local.get $acc)))
    (unreachable))
  (func $scan (export "scan") (param $n i32) (result i32)
    (local $pc i32) (local $i i32) (local $c i32)
    (loop $L
      (block $B3 (block $B2 (block $B1 (block $B0
        (br_table $B0 $B1 $B2 $B3 (local.get $pc)))
        (if (i32.ge_u (local.get $i) (local.get $n))
          (then (local.set $pc (i32.const 3)) (br $L)))
        (if (i32.eq (i32.load8_u (local.get $i)) (i32.const 42))
          (then (local.set $pc (i32.const 1)) (br $L)))
        (local.set $pc (i32.const 2)) (br $L))
        (local.set $c (i32.add (local.get $c) (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (local.set $pc (i32.const 0)) (br $L))
      (return (local.get $c)))
    (unreachable))
  (func (export "fill") (param $n i32)
    (local $i i32)
    (block $exit (loop $top
      (br_if $exit (i32.ge_u (local.get $i) (local.get $n)))
      (i32.store8 (local.get $i) (i32.rem_u (local.get $i) (i32.const 50)))
      (local.set $i (i32.add (local.get $i) (i32.const 1)))
      (br $top)))))
