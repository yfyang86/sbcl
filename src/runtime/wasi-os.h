/*
 * OS-level definitions for the WebAssembly/WASI target.
 * S0.4 stub: enough for the runtime sources to be compiled by wasi-sdk so
 * that the real porting work can be enumerated. There are no signals,
 * no ucontext, no mmap in WASI; the emulated headers from wasi-libc are
 * used where they exist (-D_WASI_EMULATED_SIGNAL, _WASI_EMULATED_MMAN).
 *
 * This software is part of the SBCL system. See the README file for
 * more information.
 */

#include <stdlib.h>
#include <sys/types.h>
#include <sys/mman.h>
#include <signal.h>
#include <string.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>

typedef char* os_vm_address_t;
typedef size_t os_vm_size_t;
typedef off_t os_vm_offset_t;
typedef int os_vm_prot_t;

#include "target-arch-os.h"
#include "target-arch.h"

/* No memory faults are ever delivered; keep the macro so that the
 * signal-handling sources compile until they are gated out. */
#define SIG_MEMORY_FAULT SIGSEGV
#ifndef SIG_STOP_FOR_GC
#define SIG_STOP_FOR_GC (SIGUSR2)
#endif

/* S0.4 second pass: shims so that the signal-oriented sources compile far
 * enough to reveal the next layer of porting work. All of this is removed
 * again once interrupt.c is gated for the wasm target. */
#ifndef SIGSTKSZ
#define SIGSTKSZ 8192
#endif
#ifndef SIG_BLOCK
#define SIG_BLOCK 0
#define SIG_UNBLOCK 1
#define SIG_SETMASK 2
typedef struct { int si_signo; int si_code; void *si_addr; } siginfo_t;
/* defined in wasm-interrupt.c: no signal is ever blocked or delivered */
int sigprocmask(int how, const sigset_t *set, sigset_t *old);
int sigaddset(sigset_t *set, int sig);
int sigemptyset(sigset_t *set);
int sigismember(const sigset_t *set, int sig);
#endif
