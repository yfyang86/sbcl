#ifndef _WASM_LINUX_OS_H
#define _WASM_LINUX_OS_H

/* S0.4 stub: there are no signal contexts in WebAssembly. A context is
 * a snapshot of the register area of the thread struct. */
typedef struct { long regs[32]; long pc; } os_context_t;
typedef long os_context_register_t;
#define OS_CONTEXT_PC(context) ((context)->pc)

#endif /* _WASM_LINUX_OS_H */
