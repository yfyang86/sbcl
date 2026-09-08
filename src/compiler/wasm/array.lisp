;;;; array operations for the WebAssembly VM

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Allocator for the array header.

(define-vop (make-array-header)
  (:policy :fast-safe)
  (:translate make-array-header)
  (:args (type :scs (any-reg) :to :save)
         (rank :scs (any-reg) :to :save))
  (:arg-types tagged-num tagged-num)
  (:temporary (:scs (descriptor-reg) :to (:result 0) :target result) header)
  (:results (result :scs (descriptor-reg)))
  (:generator 5
    ;; bytes = (rank words + the header words) rounded to a double word;
    ;; RANK is a fixnum, hence already its byte count as words
    (emit-allocate header
      (progn
        (load-reg rank)
        (inst i32.const (+ (* array-dimensions-offset n-word-bytes) lowtag-mask))
        (inst i32.add)
        (inst i32.const (lognot lowtag-mask))
        (inst i32.and)
        :pushed)
      other-pointer-lowtag)
    ;; the header word: (rank-1) in the rank field, the type (a fixnum
    ;; of the widetag) below it
    (load-reg header)
    (emit-store-word (- other-pointer-lowtag)
      (load-reg rank)
      (inst i32.const (fixnumize 1))
      (inst i32.sub)
      (inst i32.const (fixnumize array-rank-mask))
      (inst i32.and)
      (inst i32.const array-rank-position)
      (inst i32.shl)
      (load-reg type)
      (inst i32.or)
      (inst i32.const n-fixnum-tag-bits)
      (inst i32.shr_u))
    (move result header)))

;;;; Additional accessors and setters for the array header.
(define-full-reffer %array-dimension *
  array-dimensions-offset other-pointer-lowtag
  (any-reg) positive-fixnum sb-kernel:%array-dimension)

(define-full-setter %set-array-dimension *
  array-dimensions-offset other-pointer-lowtag
  (any-reg) positive-fixnum sb-kernel:%set-array-dimension)

(define-vop ()
  (:translate array-rank)
  (:policy :fast-safe)
  (:args (x :scs (descriptor-reg)))
  (:results (res :scs (unsigned-reg)))
  (:result-types positive-fixnum)
  (:generator 6
    (store-reg res
      (load-reg x)
      (emit-load-sized 1 nil (- (/ array-rank-position n-byte-bits) other-pointer-lowtag))
      (inst i32.const 1)
      (inst i32.add)
      (inst i32.const array-rank-mask)
      (inst i32.and))))

;;;; Bounds checking routine.

(define-vop (check-bound)
  (:translate %check-bound)
  (:policy :fast-safe)
  (:args (array :scs (descriptor-reg))
         (bound :scs (any-reg descriptor-reg))
         (index :scs (any-reg descriptor-reg)))
  (:variant-vars %test-fixnum)
  (:variant t)
  (:vop-var vop)
  (:save-p :compute-only)
  (:generator 6
    (let ((error (generate-error-code vop 'invalid-array-index-error array bound index)))
      (when %test-fixnum
        (%test-fixnum index nil error t))
      (load-reg index)
      (load-reg bound)
      (inst i32.ge_u)
      (inst jump-if error))))

(define-vop (check-bound/fast check-bound)
  (:policy :fast)
  (:variant nil)
  (:variant-cost 4))

(define-vop (check-bound/fixnum check-bound)
  (:args (array)
         (bound)
         (index :scs (any-reg)))
  (:arg-types * * tagged-num)
  (:variant nil)
  (:variant-cost 4))

(define-vop (check-bound/untagged check-bound)
  (:args (array)
         (bound :scs (unsigned-reg signed-reg))
         (index :scs (unsigned-reg signed-reg)))
  (:arg-types * (:or unsigned-num signed-num)
                (:or unsigned-num signed-num))
  (:variant nil)
  (:variant-cost 5))

;;;; Accessors/Setters

;;; Variants built on top of word-index-ref, etc. I.e. those vectors whos
;;; elements are represented in integer registers and are built out of
;;; 8, 16, or 32 bit elements.
(macrolet
    ((def-full-data-vector-frobs (type element-type &rest scs)
       (let ((refname (symbolicate "DATA-VECTOR-REF/" type))
             (setname (symbolicate "DATA-VECTOR-SET/" type)))
         `(progn
            (define-full-reffer ,refname ,type
              vector-data-offset other-pointer-lowtag
              ,scs ,element-type data-vector-ref)
            (define-full-setter ,setname ,type
              vector-data-offset other-pointer-lowtag ,scs ,element-type data-vector-set))))
     (def-partial-data-vector-frobs (type element-type size signed &rest scs)
       (let ((refname (symbolicate "DATA-VECTOR-REF/" type))
             (setname (symbolicate "DATA-VECTOR-SET/" type)))
         `(progn
            (define-partial-reffer ,refname ,type
              ,size ,signed vector-data-offset other-pointer-lowtag ,scs
              ,element-type data-vector-ref)
            (define-partial-setter ,setname ,type
              ,size vector-data-offset other-pointer-lowtag ,scs
              ,element-type data-vector-set))))
     (def-float-data-vector-frobs (type format element-type size complexp &rest scs)
       (let ((refname (symbolicate "DATA-VECTOR-REF/" type))
             (setname (symbolicate "DATA-VECTOR-SET/" type)))
         `(progn
            (,(if complexp
                  'define-complex-float-reffer
                  'define-float-reffer)
             ,refname ,type
             ,size ,format vector-data-offset other-pointer-lowtag ,scs
             ,element-type t "inline array access" data-vector-ref)
            (,(if complexp
                  'define-complex-float-setter
                  'define-float-setter)
             ,setname ,type
             ,size ,format vector-data-offset other-pointer-lowtag ,scs
             ,element-type t "inline array store" data-vector-set)))))
  (def-full-data-vector-frobs simple-vector * descriptor-reg any-reg)
  (def-partial-data-vector-frobs simple-base-string character 1 nil character-reg)
  #+sb-unicode
  (def-full-data-vector-frobs simple-character-string character character-reg)
  (def-partial-data-vector-frobs simple-array-unsigned-byte-7 positive-fixnum 1 nil unsigned-reg signed-reg)
  (def-partial-data-vector-frobs simple-array-signed-byte-8 tagged-num 1 t signed-reg)
  (def-partial-data-vector-frobs simple-array-unsigned-byte-8 positive-fixnum 1 nil unsigned-reg signed-reg)
  (def-partial-data-vector-frobs simple-array-unsigned-byte-15 positive-fixnum 2 nil unsigned-reg signed-reg)
  (def-partial-data-vector-frobs simple-array-signed-byte-16 tagged-num 2 t signed-reg)
  (def-partial-data-vector-frobs simple-array-unsigned-byte-16 positive-fixnum 2 nil unsigned-reg signed-reg)
  (def-full-data-vector-frobs simple-array-unsigned-byte-31 unsigned-num unsigned-reg)
  (def-full-data-vector-frobs simple-array-signed-byte-32 signed-num signed-reg)
  (def-full-data-vector-frobs simple-array-unsigned-byte-32 unsigned-num unsigned-reg)
  (def-full-data-vector-frobs simple-array-unsigned-fixnum positive-fixnum any-reg)
  (def-full-data-vector-frobs simple-array-fixnum tagged-num any-reg)
  (def-float-data-vector-frobs simple-array-single-float :single single-float 4 nil single-reg)
  (def-float-data-vector-frobs simple-array-double-float :double double-float 8 nil double-reg)
  (def-float-data-vector-frobs simple-array-complex-single-float :single complex-single-float 4 t complex-single-reg)
  (def-float-data-vector-frobs simple-array-complex-double-float :double complex-double-float 8 t complex-double-reg))

;;; Integer vectors whose elements are smaller than a byte, i.e. bit,
;;; 2-bit, and 4-bit vectors. The element is extracted from its word
;;; with shifts and masks; INDEX is an untagged element index.
(macrolet
    ((def-small-data-vector-frobs (type bits)
       (let* ((elements-per-word (floor n-word-bits bits))
              (bit-shift (1- (integer-length elements-per-word)))
              (refname (symbolicate "DATA-VECTOR-REF/" type))
              (setname (symbolicate "DATA-VECTOR-SET/" type)))
         `(progn
            (define-vop (,refname)
              (:note "inline array access")
              (:translate data-vector-ref)
              (:policy :fast-safe)
              (:args (object :scs (descriptor-reg))
                     (index :scs (unsigned-reg)))
              (:arg-types ,type positive-fixnum)
              (:results (value :scs (any-reg)))
              (:result-types positive-fixnum)
              (:generator 20
                (store-reg value
                  ;; the word
                  (load-reg object)
                  (load-reg index)
                  (inst i32.const ,bit-shift)
                  (inst i32.shr_u)
                  (inst i32.const word-shift)
                  (inst i32.shl)
                  (inst i32.add)
                  (emit-load-word (- (ash vector-data-offset word-shift) other-pointer-lowtag))
                  ;; shifted down by the element's bit position
                  (load-reg index)
                  (inst i32.const ,(1- elements-per-word))
                  (inst i32.and)
                  ,@(unless (= bits 1)
                      `((inst i32.const ,(1- (integer-length bits)))
                        (inst i32.shl)))
                  (inst i32.shr_u)
                  (inst i32.const ,(1- (ash 1 bits)))
                  (inst i32.and)
                  (inst i32.const n-fixnum-tag-bits)
                  (inst i32.shl))))
            (define-vop (,(symbolicate "DATA-VECTOR-REF-C/" type))
              (:translate data-vector-ref)
              (:policy :fast-safe)
              (:args (object :scs (descriptor-reg)))
              (:arg-types ,type
                (:constant (integer 0
                                    ,(1- (* (1+ (- (floor (+ #x7ff
                                                             other-pointer-lowtag)
                                                          n-word-bytes)
                                                   vector-data-offset))
                                            elements-per-word)))))
              (:info index)
              (:results (result :scs (unsigned-reg)))
              (:result-types positive-fixnum)
              (:generator 15
                (multiple-value-bind (word extra) (floor index ,elements-per-word)
                  (store-reg result
                    (load-reg object)
                    (emit-load-word (- (ash (+ word vector-data-offset) word-shift)
                                       other-pointer-lowtag))
                    (unless (zerop extra)
                      (inst i32.const (* extra ,bits))
                      (inst i32.shr_u))
                    (unless (= extra ,(1- elements-per-word))
                      (inst i32.const ,(1- (ash 1 bits)))
                      (inst i32.and))))))
            (define-vop (,setname)
              (:note "inline array store")
              (:translate data-vector-set)
              (:policy :fast-safe)
              (:args (object :scs (descriptor-reg) :to :save)
                     (index :scs (unsigned-reg) :to :save)
                     (value :scs (unsigned-reg immediate) :to :save))
              (:arg-types ,type positive-fixnum positive-fixnum)
              (:temporary (:scs (non-descriptor-reg)) addr shift)
              (:generator 25
                (store-reg addr
                  (load-reg object)
                  (load-reg index)
                  (inst i32.const ,bit-shift)
                  (inst i32.shr_u)
                  (inst i32.const word-shift)
                  (inst i32.shl)
                  (inst i32.add)
                  (inst i32.const (- (ash vector-data-offset word-shift) other-pointer-lowtag))
                  (inst i32.add))
                (store-reg shift
                  (load-reg index)
                  (inst i32.const ,(1- elements-per-word))
                  (inst i32.and)
                  ,@(unless (= bits 1)
                      `((inst i32.const ,(1- (integer-length bits)))
                        (inst i32.shl))))
                ;; word := (word & ~(mask << shift)) | ((value & mask) << shift)
                (load-reg addr)
                (emit-store-word 0
                  (load-reg addr)
                  (inst i32.load 0)
                  (inst i32.const ,(1- (ash 1 bits)))
                  (load-reg shift)
                  (inst i32.shl)
                  (inst i32.const -1)
                  (inst i32.xor)
                  (inst i32.and)
                  (sc-case value
                    (immediate
                     (inst i32.const (logand (tn-value value) ,(1- (ash 1 bits)))))
                    (unsigned-reg
                     (load-reg value)
                     (inst i32.const ,(1- (ash 1 bits)))
                     (inst i32.and)))
                  (load-reg shift)
                  (inst i32.shl)
                  (inst i32.or))))
            (define-vop (,(symbolicate "DATA-VECTOR-SET-C/" type))
              (:translate data-vector-set)
              (:policy :fast-safe)
              (:args (object :scs (descriptor-reg))
                     (value :scs (unsigned-reg immediate)))
              (:arg-types ,type
                          (:constant
                           (integer 0
                                    ,(1- (* (1+ (- (floor (+ #x7ff
                                                             other-pointer-lowtag)
                                                          n-word-bytes)
                                                   vector-data-offset))
                                            elements-per-word))))
                          positive-fixnum)
              (:info index)
              (:generator 20
                (multiple-value-bind (word extra) (floor index ,elements-per-word)
                  (let ((displacement (- (ash (+ word vector-data-offset) word-shift)
                                         other-pointer-lowtag)))
                    (load-reg object)
                    (emit-store-word displacement
                      (load-reg object)
                      (emit-load-word displacement)
                      (inst i32.const (lognot (ash ,(1- (ash 1 bits)) (* extra ,bits))))
                      (inst i32.and)
                      (sc-case value
                        (immediate
                         (inst i32.const (ash (logand (tn-value value) ,(1- (ash 1 bits)))
                                              (* extra ,bits))))
                        (unsigned-reg
                         (load-reg value)
                         (inst i32.const ,(1- (ash 1 bits)))
                         (inst i32.and)
                         (inst i32.const (* extra ,bits))
                         (inst i32.shl)))
                      (inst i32.or))))))))))
  (def-small-data-vector-frobs simple-bit-vector 1)
  (def-small-data-vector-frobs simple-array-unsigned-byte-2 2)
  (def-small-data-vector-frobs simple-array-unsigned-byte-4 4))

;;; These vops are useful for accessing the bits of a vector
;;; irrespective of what type of vector it is.
(define-full-reffer vector-raw-bits * vector-data-offset other-pointer-lowtag
  (unsigned-reg) unsigned-num %vector-raw-bits)
(define-full-setter set-vector-raw-bits * vector-data-offset other-pointer-lowtag
  (unsigned-reg) unsigned-num %set-vector-raw-bits)

;;;; Atomic operations (one thread: load, compare, conditional store).

(define-full-casser data-vector-cas/simple-vector simple-vector vector-data-offset other-pointer-lowtag
  (any-reg descriptor-reg) * %compare-and-swap-svref)

(define-vop (array-atomic-incf/word)
  (:translate %array-atomic-incf/word)
  (:policy :fast-safe)
  (:args (object :scs (descriptor-reg) :to :save)
         (index :scs (any-reg) :to :save)
         (diff :scs (unsigned-reg) :to :save))
  (:arg-types * tagged-num unsigned-num)
  (:results (result :scs (unsigned-reg) :from :load))
  (:result-types unsigned-num)
  (:generator 5
    (let ((displacement (- (* vector-data-offset n-word-bytes) other-pointer-lowtag)))
      (store-reg result
        (emit-indexed-address object index n-word-bytes)
        (emit-load-word displacement))
      (emit-indexed-address object index n-word-bytes)
      (emit-store-word displacement
        (load-reg result)
        (load-reg diff)
        (inst i32.add)))))
