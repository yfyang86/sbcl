;;;; the WebAssembly definitions of VOPs used for non-local exit (throw,
;;;; lexical exit, etc.)

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;;; Non-local exit (doc/wasm-port/02-design.md, 2.6)
;;;;
;;;; A catch or unwind block records the frame (CFP) and, instead of a
;;;; return address, the dispatcher index of its entry label within the
;;;; function that established it (LABEL-INDEX). The UNWIND assembly
;;;; routine stores the target block in the thread and throws the
;;;; LISP_UNWIND tag; the function's exception handler (see func-asm.lisp)
;;;; recognizes its own block by the frame and enters the NLX entry
;;;; through the dispatcher, with the values' start and count in OCFP and
;;;; NARGS as on the other targets.

;;; Make a TN for the argument count passing location for a non-local
;;; entry.
(defun make-nlx-entry-arg-start-location ()
  (make-wired-tn *fixnum-primitive-type* any-reg-sc-number ocfp-offset))

;;; Save and restore dynamic environment.
;;;
;;; These VOPs are used in the reentered function to restore the
;;; appropriate dynamic environment. Currently we only save the
;;; Current-Catch and binding stack pointer. We don't need to save/restore
;;; the current unwind-protect, since unwind-protects are implicitly
;;; processed during unwinding. If there were any additional stacks, then
;;; this would be the place to restore the top pointers.

(define-vop (save-dynamic-state)
  (:results (catch :scs (descriptor-reg))
            (nfp :scs (descriptor-reg))
            (nsp :scs (descriptor-reg)))
  (:vop-var vop)
  (:generator 13
    (load-current-catch-block catch)
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (move nfp cur-nfp)))
    (move nsp nsp-tn)))

(define-vop (restore-dynamic-state)
  (:args (catch :scs (descriptor-reg))
         (nfp :scs (descriptor-reg))
         (nsp :scs (descriptor-reg)))
  (:vop-var vop)
  (:generator 10
    (store-current-catch-block catch)
    (let ((cur-nfp (current-nfp-tn vop)))
      (when cur-nfp
        (move cur-nfp nfp)))
    (move nsp-tn nsp)))

(define-vop (current-stack-pointer)
  (:results (res :scs (any-reg descriptor-reg)))
  (:generator 1
    (move res csp-tn)))

(define-vop (current-binding-pointer)
  (:results (res :scs (any-reg descriptor-reg)))
  (:generator 1
    (load-binding-stack-pointer res)))

(define-vop (current-nsp)
  (:results (res :scs (any-reg descriptor-reg)))
  (:generator 1
    (move res nsp-tn)))

(define-vop (set-nsp)
  (:args (nsp :scs (any-reg descriptor-reg)))
  (:generator 1
    (move nsp-tn nsp)))

;;;; Unwind block hackery:

;;; Store the entry index of ENTRY-LABEL in the block's entry-pc slot.
(defun store-entry-index (block entry-label)
  (load-reg block)
  (emit-store-word (ash unwind-block-entry-pc-slot word-shift)
    (inst label-index entry-label)))

;;; Compute the address of the catch block from its TN, then store into
;;; the block the current Fp, Env, Unwind-Protect, and the entry PC.
(define-vop (make-unwind-block)
  (:args (tn))
  (:info entry-label)
  (:results (block :scs (any-reg)))
  (:temporary (:scs (descriptor-reg)) temp)
  (:generator 22
    (store-reg block (emit-reg-plus cfp-tn (tn-byte-offset tn)))
    (load-current-unwind-protect-block temp)
    (storew temp block unwind-block-uwp-slot)
    (storew cfp-tn block unwind-block-cfp-slot)
    (storew code-tn block unwind-block-code-slot)
    (store-entry-index block entry-label)))

;;; Like Make-Unwind-Block, except that we also store in the specified
;;; tag, and link the block into the Current-Catch list.
(define-vop (make-catch-block)
  (:args (tn)
         (tag :scs (any-reg descriptor-reg)))
  (:info entry-label)
  (:results (block :scs (any-reg)))
  (:temporary (:scs (descriptor-reg)) temp)
  (:temporary (:scs (descriptor-reg) :target block :to (:result 0)) result)
  (:generator 44
    (store-reg result (emit-reg-plus cfp-tn (tn-byte-offset tn)))
    (load-current-unwind-protect-block temp)
    (storew temp result catch-block-uwp-slot)
    (storew cfp-tn result catch-block-cfp-slot)
    (storew code-tn result catch-block-code-slot)
    (store-entry-index result entry-label)
    (storew tag result catch-block-tag-slot)
    (load-current-catch-block temp)
    (storew temp result catch-block-previous-catch-slot)
    (store-current-catch-block result)
    (move block result)))

;;; Set up the unwind protect for the current frame.
(define-vop (set-unwind-protect)
  (:args (uwp :scs (any-reg)))
  (:generator 7
    (store-current-unwind-protect-block uwp)))

(define-vop (%catch-breakup)
  (:args (current-block))
  (:ignore current-block)
  (:temporary (:scs (any-reg)) block)
  (:policy :fast-safe)
  (:generator 17
    (load-current-catch-block block)
    (loadw block block catch-block-previous-catch-slot)
    (store-current-catch-block block)))

(define-vop (%unwind-protect-breakup)
  (:args (current-block))
  (:ignore current-block)
  (:temporary (:scs (any-reg)) block)
  (:policy :fast-safe)
  (:generator 17
    (load-current-unwind-protect-block block)
    (loadw block block unwind-block-uwp-slot)
    (store-current-unwind-protect-block block)))

;;;; NLX entry VOPs:

;;; The NLX-ENTRY pseudo-instruction marks LABEL as an entry of the
;;; function's exception handler.
(defun emit-nlx-entry-label (label vop)
  (emit-label label)
  (inst nlx-entry label)
  (note-this-location vop :non-local-entry))

(define-vop (nlx-entry)
  (:args (sp) ; Note: we can't list an sc-restriction, 'cause any load vops
              ; would be inserted before the LRA.
         (start)
         (count))
  (:results (values :more t :from :load))
  (:temporary (:scs (descriptor-reg)) move-temp)
  (:info label nvals)
  (:save-p :force-to-stack)
  (:vop-var vop)
  (:generator 30
    (emit-nlx-entry-label label vop)
    (cond ((zerop nvals))
          ((= nvals 1)
           (let ((no-values (gen-label)))
             (load-immediate-word (tn-ref-tn values) nil-value)
             (load-reg count)
             (inst i32.eqz)
             (inst jump-if no-values)
             (loadw (tn-ref-tn values) start)
             (emit-label no-values)))
          (t
           (do ((i 0 (1+ i))
                (tn-ref values (tn-ref-across tn-ref)))
               ((null tn-ref))
             (let ((tn (tn-ref-tn tn-ref))
                   (less-than (gen-label)))
               (sc-case tn
                 ((descriptor-reg any-reg)
                  (load-immediate-word tn nil-value)
                  (load-reg count)
                  (inst i32.const (fixnumize i))
                  (inst i32.le_s)
                  (inst jump-if less-than)
                  (loadw tn start i)
                  (emit-label less-than))
                 (control-stack
                  (load-immediate-word move-temp nil-value)
                  (load-reg count)
                  (inst i32.const (fixnumize i))
                  (inst i32.le_s)
                  (inst jump-if less-than)
                  (loadw move-temp start i)
                  (emit-label less-than)
                  (store-stack-tn tn move-temp)))))))
    (load-stack-tn csp-tn sp)))

(define-vop (nlx-entry-single)
  (:args (sp)
         (value))
  (:results (res :from :load))
  (:info label)
  (:save-p :force-to-stack)
  (:vop-var vop)
  (:generator 30
    (emit-nlx-entry-label label vop)
    (move res value)
    (load-stack-tn csp-tn sp)))

(define-vop (nlx-entry-multiple)
  (:args (top :target result)
         (src)
         (count))
  (:info label)
  (:temporary (:scs (any-reg)) dst)
  (:temporary (:scs (descriptor-reg)) temp)
  (:results (result :scs (any-reg) :from (:argument 0))
            (num :scs (any-reg) :from (:argument 0)))
  (:save-p :force-to-stack)
  (:vop-var vop)
  (:generator 30
    (emit-nlx-entry-label label vop)
    (let ((loop (gen-label))
          (done (gen-label)))
      (load-stack-tn result top)
      (move num count)
      (store-reg csp-tn
        (load-reg result)
        (load-reg count)
        (inst i32.add))
      (load-reg count)
      (inst i32.eqz)
      (inst jump-if done)
      (move dst result)
      (emit-label loop)
      (loadw temp src)
      (store-reg src (emit-reg-plus src n-word-bytes))
      (storew temp dst)
      (store-reg dst (emit-reg-plus dst n-word-bytes))
      (load-reg dst)
      (load-reg csp-tn)
      (inst i32.ne)
      (inst jump-if loop)
      (emit-label done))))

;;; This VOP is just to force the TNs used in the cleanup onto the stack.
(define-vop (uwp-entry)
  (:info label)
  (:save-p :force-to-stack)
  (:results (block) (start) (count))
  (:ignore block start count)
  (:vop-var vop)
  (:generator 0
    (emit-nlx-entry-label label vop)))
