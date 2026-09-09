/*
 * WebAssembly/WASI: the arch-and-OS-dependent definitions. There are no
 * signal contexts; an os_context_t is a snapshot of the Lisp register
 * area (wasm-arch.c), used by the few common sources that inspect one.
 *
 * This software is part of the SBCL system. See the README file for
 * more information.
 */
#ifndef _WASM_WASI_OS_H
#define _WASM_WASI_OS_H

#include <stdint.h>
/* regs: the register area at the error; pc: the start of the current
 * code object's instructions (there is no program counter, this lets
 * the debugger find the component); error: trap kind, error code,
 * argument count and the SC+OFFSET words of the arguments, as
 * INTERNAL-ERROR-ARGS (src/code/wasm-vm.lisp) reads them */
typedef struct { uint32_t regs[32]; uint32_t pc; uint32_t error[3 + 16]; } os_context_t;
typedef uint32_t os_context_register_t;
#define OS_CONTEXT_PC(context) ((context)->pc)

#endif /* _WASM_WASI_OS_H */
