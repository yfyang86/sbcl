/*
 * The Lisp register file of the WebAssembly target: word slots of the
 * per-thread register area (src/compiler/wasm/vm.lisp, macros.lisp),
 * addressed from the "thread" global by compiled code and through
 * lisp_register_area (wasm-arch.c) by the runtime.
 *
 * This software is part of the SBCL system. See the README file for
 * more information.
 */

#define REG(num) num
#define NREGS (32)

#define reg_NARGS    REG(0)
#define reg_CSP      REG(1)
#define reg_CFP      REG(2)
#define reg_OCFP     REG(3)
#define reg_NFP      REG(4)
#define reg_NSP      REG(5)
#define reg_LEXENV   REG(6)
#define reg_CODE     REG(7)
#define reg_LIP      REG(8)
#define reg_CFUNC    REG(9)
#define reg_A0       REG(10)
#define reg_A1       REG(11)
#define reg_A2       REG(12)
#define reg_A3       REG(13)
#define reg_L0       REG(14)
#define reg_L1       REG(15)
#define reg_L2       REG(16)
#define reg_L3       REG(17)
#define reg_L4       REG(18)
#define reg_L5       REG(19)
#define reg_NL0      REG(20)
#define reg_NL1      REG(21)
#define reg_NL2      REG(22)
#define reg_NL3      REG(23)
#define reg_NL4      REG(24)
#define reg_NL5      REG(25)
#define reg_NL6      REG(26)
#define reg_NL7      REG(27)
#define reg_TMP      REG(28)
#define reg_RA       REG(29)

#define reg_LINK_RETURN reg_RA

/* byte offsets within the register area (macros.lisp) */
#define LISP_REGISTER_AREA_FLOATS   128
#define LISP_REGISTER_AREA_ERROR_ARGS 384
#define LISP_REGISTER_AREA_UNWIND_TARGET 448
#define LISP_REGISTER_AREA_FLOAT_MODES 452
/* set by the host on Ctrl-C, serviced by pending_interrupt (wasm-arch.c) */
#define LISP_REGISTER_AREA_INTERRUPT_PENDING 456
#define LISP_REGISTER_AREA_SIZE     512
