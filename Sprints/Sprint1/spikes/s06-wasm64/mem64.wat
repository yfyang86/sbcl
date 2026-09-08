;; S0.6: memory64 probe. A 64-bit-addressed memory of 5 GiB is more than
;; wasm32 can address; store and load a word above the 4 GiB line.
(module
  (memory i64 81920) ;; 81920 pages * 64KiB = 5 GiB
  (func (export "probe") (result i64)
    (i64.store (i64.const 0x1_0000_0010) (i64.const 0x1234_5678_9abc_def0))
    (i64.load (i64.const 0x1_0000_0010)))
  (func (export "size_pages") (result i64) (memory.size)))
