;; S0.2: Wasm exception handling (try_table / throw / exnref) across deep
;; recursion, with catch-and-rethrow in the middle, and tail calls.
(module
  (tag $lisp_unwind)
  (global $target (mut i32) (i32.const 0))
  (global $frames (mut i32) (i32.const 0))

  ;; recurse depth times, then throw. Every 100th frame has a handler that
  ;; checks whether it is the target and rethrows otherwise, modelling a
  ;; Lisp function with an NLX entry.
  (func $recurse (param $depth i32) (param $id i32) (result i32)
    (local $r i32)
    (if (i32.eqz (local.get $depth))
      (then (throw $lisp_unwind)))
    (if (i32.eqz (i32.rem_u (local.get $id) (i32.const 100)))
      (then
        (block $handler
          (try_table (catch $lisp_unwind $handler)
            (local.set $r (call $recurse (i32.sub (local.get $depth) (i32.const 1))
                                         (i32.add (local.get $id) (i32.const 1))))
            (return (local.get $r)))
        )
        ;; handler: is this frame the target?
        (global.set $frames (i32.add (global.get $frames) (i32.const 1)))
        (if (i32.eq (local.get $id) (global.get $target))
          (then (return (local.get $id))))
        (throw $lisp_unwind)))
    (return (call $recurse (i32.sub (local.get $depth) (i32.const 1))
                           (i32.add (local.get $id) (i32.const 1)))))

  ;; unwind through `depth` frames, catching at frame `target`
  (func (export "unwind_test") (param $depth i32) (param $target i32) (result i32)
    (global.set $target (local.get $target))
    (global.set $frames (i32.const 0))
    (block $top
      (try_table (catch $lisp_unwind $top)
        (return (call $recurse (local.get $depth) (i32.const 0)))))
    (i32.const -1))
  (func (export "frames_visited") (result i32) (global.get $frames))

  ;; tail calls: count down n with return_call; without tail calls this
  ;; overflows the engine stack for n = 10^7.
  (func $count (param $n i32) (param $acc i32) (result i32)
    (if (i32.eqz (local.get $n)) (then (return (local.get $acc))))
    (return_call $count (i32.sub (local.get $n) (i32.const 1))
                        (i32.add (local.get $acc) (i32.const 1))))
  (func (export "tail_test") (param $n i32) (result i32)
    (call $count (local.get $n) (i32.const 0)))

  ;; indirect tail call through a table, as Lisp full calls would use
  (type $lispfn (func (param i32 i32) (result i32)))
  (table $t 2 funcref)
  (elem (i32.const 0) $count $count_indirect)
  (func $count_indirect (param $n i32) (param $acc i32) (result i32)
    (if (i32.eqz (local.get $n)) (then (return (local.get $acc))))
    (return_call_indirect $t (type $lispfn)
      (i32.sub (local.get $n) (i32.const 1))
      (i32.add (local.get $acc) (i32.const 1))
      (i32.const 1)))
  (func (export "tail_indirect_test") (param $n i32) (result i32)
    (call $count_indirect (local.get $n) (i32.const 0)))
)
