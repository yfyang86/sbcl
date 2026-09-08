;;;; allocation VOPs for the WebAssembly target

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Every allocation goes through the runtime's ALLOC import, which
;;;; returns zeroed memory (doc/wasm-port/02-design.md, 2.8); the inline
;;;; bump allocator and stack allocation come with the runtime port, so
;;;; STACK-ALLOCATE-P is accepted and ignored here: heap allocation is
;;;; always a correct implementation of dynamic extent.

;;;; LIST and LIST*
(define-vop (list)
  (:args (things :more t :scs (any-reg descriptor-reg control-stack)))
  (:temporary (:scs (descriptor-reg)) ptr)
  (:temporary (:scs (descriptor-reg) :to (:result 0) :target result) res)
  (:temporary (:scs (any-reg)) temp)
  (:info star cons-cells)
  (:results (result :scs (descriptor-reg)))
  (:generator 0
    (flet ((maybe-load (tn)
             (sc-case tn
               ((any-reg descriptor-reg) tn)
               (control-stack
                (load-stack-tn temp tn)
                temp))))
      (let ((alloc (* (pad-data-block cons-size) cons-cells)))
        (emit-allocate res alloc list-pointer-lowtag :list t)
        (let ((ptr (if (= cons-cells 1) res ptr)))
          (move ptr res)
          (dotimes (i (1- cons-cells))
            (storew (maybe-load (tn-ref-tn things)) ptr
                    cons-car-slot list-pointer-lowtag)
            (setf things (tn-ref-across things))
            (store-reg ptr
              (load-reg ptr)
              (inst i32.const (pad-data-block cons-size))
              (inst i32.add))
            (storew ptr ptr (- cons-cdr-slot cons-size) list-pointer-lowtag))
          (storew (maybe-load (tn-ref-tn things)) ptr
                  cons-car-slot list-pointer-lowtag)
          (cond (star
                 (storew (maybe-load (tn-ref-tn (tn-ref-across things)))
                         ptr cons-cdr-slot list-pointer-lowtag))
                (t
                 (load-reg ptr)
                 (emit-store-word (- (ash cons-cdr-slot word-shift) list-pointer-lowtag)
                   (inst i32.const nil-value)))))
        (move result res)))))

;;;; Special purpose inline allocators.

;;; The raw-addr slot gets the table entry of the undefined-function
;;; trampoline (see cell.lisp).
(define-vop (make-fdefn)
  (:args (name :scs (descriptor-reg) :to :save))
  (:results (result :scs (descriptor-reg)))
  (:policy :fast-safe)
  (:translate make-fdefn)
  (:generator 37
    (with-fixed-allocation (result fdefn-widetag fdefn-size)
      (storew name result fdefn-name-slot other-pointer-lowtag)
      (load-reg result)
      (emit-store-word (- (ash fdefn-fun-slot word-shift) other-pointer-lowtag)
        (inst i32.const nil-value))
      (load-reg result)
      (emit-store-word (- (ash fdefn-raw-addr-slot word-shift) other-pointer-lowtag)
        (inst i32.const (make-fixup 'undefined-tramp :assembly-routine-entry))))))

;;; Push the byte size of a vector of WORDS (a fixnum) data words,
;;; including the header and length words, rounded to a double word.
(defun emit-vector-byte-size (words)
  (load-reg words)
  (inst i32.const (* (1+ vector-data-offset) n-word-bytes))
  (inst i32.add)
  (inst i32.const (lognot lowtag-mask))
  (inst i32.and)
  :pushed)

(define-vop (allocate-vector-on-heap)
  (:args (type :scs (unsigned-reg) :to :save)
         (length :scs (any-reg) :to :save)
         (words :scs (any-reg) :to :save))
  (:arg-types positive-fixnum
              positive-fixnum
              positive-fixnum)
  (:results (result :scs (descriptor-reg) :from :load))
  (:policy :fast-safe)
  (:generator 100
    (emit-allocate result (emit-vector-byte-size words) other-pointer-lowtag)
    (storew type result 0 other-pointer-lowtag)
    (storew length result vector-length-slot other-pointer-lowtag)))

(define-vop (allocate-vector-on-stack allocate-vector-on-heap)
  (:vop-var vop)
  (:node-var node)
  (:ignore vop node))

(define-vop (make-closure)
  (:args (function :to :save :scs (descriptor-reg)))
  (:info label length stack-allocate-p)
  (:ignore label stack-allocate-p)
  (:results (result :scs (descriptor-reg)))
  (:generator 10
    (let* ((size (+ length closure-info-offset))
           (alloc-size (pad-data-block size)))
      (emit-allocate result alloc-size fun-pointer-lowtag)
      (load-reg result)
      (emit-store-word (- fun-pointer-lowtag)
        (inst i32.const (logior (ash (1- size) n-widetag-bits) closure-widetag)))
      (storew function result closure-fun-slot fun-pointer-lowtag))))

;;; The compiler magically generates calls to this for dynamic-extent
;;; value cells (see the comment in the :GENERATOR).
(define-vop (make-value-cell)
  (:args (value :to :save :scs (descriptor-reg any-reg)))
  (:results (result :scs (descriptor-reg)))
  (:generator 10
    (with-fixed-allocation (result value-cell-widetag value-cell-size)
      (storew value result value-cell-value-slot other-pointer-lowtag))))

;;;; Automatic allocators for primitive objects.

(define-vop (make-unbound-marker)
  (:args)
  (:results (result :scs (descriptor-reg any-reg)))
  (:generator 1
    (load-immediate-word result unbound-marker-widetag)))

(define-vop (fixed-alloc)
  (:args)
  (:info name words type lowtag stack-allocate-p)
  (:ignore name stack-allocate-p)
  (:results (result :scs (descriptor-reg)))
  (:generator 4
    (with-fixed-allocation (result type words :lowtag lowtag))))

(define-vop (var-alloc)
  (:args (extra :scs (any-reg) :to :save))
  (:arg-types positive-fixnum)
  (:info name words type lowtag stack-allocate-p)
  (:ignore name stack-allocate-p)
  (:temporary (:scs (any-reg)) bytes)
  (:results (result :scs (descriptor-reg)))
  (:generator 6
    ;; bytes = the payload size: EXTRA (a fixnum, hence already a byte
    ;; count of words) plus the fixed words after the header
    (store-reg bytes
      (load-reg extra)
      (inst i32.const (* (1- words) n-word-bytes))
      (inst i32.add))
    (emit-allocate result
      (progn
        (load-reg bytes)
        (unless (= type code-header-widetag)
          (inst i32.const (* 2 n-word-bytes))
          (inst i32.add))
        (inst i32.const (lognot lowtag-mask))
        (inst i32.and)
        :pushed)
      lowtag)
    (load-reg result)
    (emit-store-word (- lowtag)
      (load-reg bytes)
      (inst i32.const (- (length-field-shift type) word-shift))
      (inst i32.shl)
      (inst i32.const type)
      (inst i32.add))))
