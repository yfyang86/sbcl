/*
 * WebAssembly: the pieces of interrupt.c the common sources need. There
 * are no signals; interrupts are polled (doc/wasm-port/02-design.md, 2.7)
 * and nothing is delivered yet.
 *
 * This software is part of the SBCL system. See the README file for
 * more information.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "genesis/sbcl.h"
#include "runtime.h"
#include "os.h"
#include "interrupt.h"
#include "interr.h"
#include "globals.h"
#include "thread.h"
#include "arch.h"
#include "genesis/static-symbols.h"

sigset_t deferrable_sigset, blockable_sigset, gc_sigset, thread_start_sigset;

/* read (and set) by cold-init through the linkage table */
int internal_errors_enabled = 0;

/* Lisp-visible signal interface: nothing to install, no signal info */
void install_handler(int signal, lispobj handler) {}
int siginfo_code(siginfo_t *info) { return 0; }

/* sprof.c is compiled out */
void allocator_record_backtrace(void* frame_ptr, struct thread* thread) {}

/* The sigset functions wasi-libc does not provide (declared in wasi-os.h;
 * sigprocmask is also a foreign symbol of the core). Nothing is ever
 * blocked because nothing is ever delivered. */
void sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
    if (old) *old = 0;
}
int sb_sigprocmask(int how, const sigset_t *set, sigset_t *old)
{
    sigprocmask(how, set, old);
    return 0;
}
int sigaddset(sigset_t *set, int sig) { return 0; }
int sigemptyset(sigset_t *set) { return 0; }
int sigismember(const sigset_t *set, int sig) { return 0; }
lispobj lisp_sig_handlers[NSIG];

void sigset_tostring(const sigset_t *sigset, char* result, int result_length)
{
    if (result_length > 0) result[0] = 0;
}
void sigaddset_blockable(sigset_t *s) {}
bool deferrables_blocked_p(sigset_t *sigset) { return 1; }
void check_deferrables_blocked_or_lose(sigset_t *sigset) {}
void check_deferrables_unblocked_or_lose(sigset_t *sigset) {}
void check_gc_signals_unblocked_or_lose(sigset_t *sigset) {}
void block_deferrable_signals(sigset_t *old) {}
void block_blockable_signals(sigset_t *old) {}
void unblock_deferrable_signals(sigset_t *where) {}
void unblock_gc_stop_signal(void) {}
void maybe_save_gc_mask_and_block_deferrables(os_context_t *context) {}

void interrupt_init(void) {}
bool interrupt_handler_pending_p(void) { return 0; }

/* The GC is only ever entered from the allocation slow path, where every
 * Lisp value is in the register area or on the control stack: there is
 * no foreign function call to fake. */
void fake_foreign_function_call(os_context_t* context) {}
void fake_foreign_function_call_noassert(os_context_t *context) {}
void undo_fake_foreign_function_call(os_context_t* context) {}

void arrange_return_to_c_function(os_context_t *context, call_into_lisp_lookalike f, lispobj arg)
{
    lose("arrange_return_to_c_function is not possible on WebAssembly");
}
void arrange_return_to_lisp_function(os_context_t *context, lispobj function)
{
    lose("arrange_return_to_lisp_function is not possible on WebAssembly");
}

void interrupt_handle_now(int signal, siginfo_t *info, os_context_t *context) {}
void interrupt_handle_pending(os_context_t *context) {}
void interrupt_internal_error(os_context_t *context, bool continuable)
{
    lose("interrupt_internal_error: no context on WebAssembly");
}
bool handle_guard_page_triggered(os_context_t *context, os_vm_address_t addr) { return 0; }
extern void wasm_pending_interrupt(void);
void do_pending_interrupt(void) { wasm_pending_interrupt(); }
void sig_stop_for_gc_handler(int signal, siginfo_t *info, os_context_t *context) {}
void ll_install_handler(int signal, interrupt_handler_t handler) {}
void handle_trap(os_context_t *context, int trap)
{
    lose("handle_trap: no trap instructions on WebAssembly");
}
void lisp_memory_fault_error(os_context_t *context, os_vm_address_t addr)
{
    lose("memory fault at %p", addr);
}
void lower_thread_control_stack_guard_page(struct thread *th) {}
void reset_thread_control_stack_guard_page(struct thread *th) {}
void lower_thread_alien_stack_guard_page(struct thread *th) {}
void reset_thread_alien_stack_guard_page(struct thread *th) {}
void lower_thread_binding_stack_guard_page(struct thread *th) {}
void reset_thread_binding_stack_guard_page(struct thread *th) {}

/* The linkage-table guard ENSURE-ALIEN-LINKAGE-INDEX gives an alien
 * function the runtime does not define (interrupt.c's, for the targets
 * without an undefined_alien_function trampoline): entered when such a
 * function is called with a matching signature. */
void undefined_alien_function(void)
{
    funcall0(StaticSymbolFunction(UNDEFINED_ALIEN_FUN_ERROR));
}
