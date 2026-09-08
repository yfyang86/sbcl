;;;; This file contains some parameterizations of various VM
;;;; attributes for the WebAssembly target. Most of the parameters
;;;; that are common to all targets live in generic/parms.lisp.

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB-VM")

;;; Wasm bytecode is a byte stream: no instruction scheduling and no
;;; alignment constraints.
(defconstant sb-assem:assem-scheduler-p nil)
(defconstant sb-assem:+inst-alignment-bytes+ 1)

(defconstant sb-fasl:+backend-fasl-file-implementation+
  #-64-bit :wasm32 #+64-bit :wasm64)

;;; The GC page. There is no memory protection in linear memory, so this
;;; is purely the granularity at which the collector claims memory for
;;; allocation regions. A Wasm memory page is 64 KiB; the GC page need not
;;; match it.
(defconstant +backend-page-bytes+ 32768)
(defconstant gencgc-page-bytes +backend-page-bytes+)

;;; Writes to old generations are logged in software (soft card marks);
;;; a card is a fraction of a GC page.
(defconstant cards-per-page 32)

;;; The minimum size of new allocation regions.
(defconstant gencgc-alloc-granularity 0)

;;; number of bits per word where a word holds one lisp descriptor
(defconstant n-word-bits #-64-bit 32 #+64-bit 64)

;;; the natural width of a machine word (as seen in e.g. register width,
;;; address space)
(defconstant n-machine-word-bits #-64-bit 32 #+64-bit 64)

;;; Wasm floating point has no traps and no rounding-mode control.
;;; FLOATING-POINT-MODES is a software word laid out like this so that the
;;; generic float-trap code compiles; the trap bits are never enabled.
(defconstant float-invalid-trap-bit        (ash 1 0))
(defconstant float-divide-by-zero-trap-bit (ash 1 1))
(defconstant float-overflow-trap-bit       (ash 1 2))
(defconstant float-underflow-trap-bit      (ash 1 3))
(defconstant float-inexact-trap-bit        (ash 1 4))

(defconstant float-round-to-nearest  0)
(defconstant float-round-to-zero     1)
(defconstant float-round-to-negative 2)
(defconstant float-round-to-positive 3)

(defconstant-eqx float-rounding-mode   (byte 2 5) #'equalp)
(defconstant-eqx float-sticky-bits     (byte 5 0) #'equalp)
(defconstant-eqx float-traps-byte      (byte 0 0) #'equalp) ; no traps
(defconstant-eqx float-exceptions-byte (byte 5 0) #'equalp)
(defconstant float-fast-bit 0)

;;;; Memory layout
;;;;
;;;; One linear memory. The C runtime (wasi-libc data segment and its
;;;; shadow stack) owns the lowest region. The Lisp spaces start at 16 MiB
;;;; and are fixed at genesis time; the runtime grows the memory to cover
;;;; them. Dynamic space starts at 256 MiB. The layout is the same for
;;;; wasm64 until a larger heap is actually wanted.

(gc-space-setup #x01000000 :dynamic-space-start #x10000000)

;;; The alien linkage table holds data words, not code stubs: a function
;;; entry is an index into the shared funcref table, a data entry is an
;;; address. See doc/wasm-port/02-design.md, 2.9.
(defconstant alien-linkage-table-entry-size #-64-bit 4 #+64-bit 8)
(defconstant alien-linkage-table-growth-direction :up)
(setq *alien-linkage-table-predefined-entries* '(("alloc" nil)
                                                 ("alloc_list" nil)))

;;;; other miscellaneous constants

;;; Trap codes. There are no trap instructions; an error trap is a call
;;; to the runtime with the trap code and the error arguments.
(defenum (:start 8)
  halt-trap
  pending-interrupt-trap
  cerror-trap
  breakpoint-trap
  fun-end-breakpoint-trap
  single-step-around-trap
  single-step-before-trap
  invalid-arg-count-trap
  error-trap)

;;; Assembly routines the C runtime looks up by static symbol. On this
;;; target CALL-INTO-LISP and the pending-interrupt entry are C; there are
;;; none.
(eval-when (:compile-toplevel :load-toplevel :execute)
  (defparameter *runtime-asm-routines* '()))

;;;; Static symbols.

;;; These symbols are loaded into static space directly after NIL so
;;; that the system can compute their address by adding a constant
;;; amount to NIL.
(defconstant-eqx +static-symbols+
 `#(,@+common-static-symbols+
    #-sb-thread
    ,@'(*binding-stack-pointer*
        ;; interrupt handling
        *pseudo-atomic-atomic*
        *pseudo-atomic-interrupted*)
    ,@*runtime-asm-routines*)
  #'equalp)

(defconstant-eqx +static-fdefns+ `#(,@common-static-fdefns) #'equalp)

;;;; Assembler parameters:

;;; The number of bits per element in the assembler's code vector.
(defparameter *assembly-unit-length* 8)
