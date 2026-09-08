#ifndef _WASM_ARCH_H
#define _WASM_ARCH_H

#include <stdint.h>

/* The Lisp register file: a fixed area in linear memory that compiled
 * Lisp code reaches through the module's thread global. Layout in
 * wasm-lispregs.h; defined in wasm-arch.c. */
extern uint32_t lisp_register_area[];

#endif /* _WASM_ARCH_H */
