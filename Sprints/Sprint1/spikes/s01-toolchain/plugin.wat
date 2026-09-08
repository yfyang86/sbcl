;; S0.1: a module "compiled at runtime": imports the runtime's memory and
;; table, installs two functions at table_base and table_base+1.
(module
  (import "env" "memory" (memory 1))
  (import "env" "__indirect_function_table" (table $t 0 funcref))
  (import "env" "table_base" (global $base i32))
  (type $lispfn (func (param i32) (result i32)))
  (func $double (type $lispfn)
    (i32.store (i32.const 1024) (i32.mul (local.get 0) (i32.const 2)))
    (i32.mul (local.get 0) (i32.const 2)))
  (func $plus100 (type $lispfn)
    (i32.store (i32.const 1024) (i32.add (local.get 0) (i32.const 100)))
    (i32.add (local.get 0) (i32.const 100)))
  (elem (global.get $base) $double $plus100))
