/*
 * WebAssembly/WASI: the OS-dependent runtime support. No signals, no
 * memory protection, no instruction cache, no executable path; the host
 * (sbcl-wasm, or a browser) provides what WASI does not.
 *
 * This software is part of the SBCL system. See the README file for
 * more information.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>

#include "genesis/sbcl.h"
#include "os.h"
#include "arch.h"
#include "globals.h"
#include "interrupt.h"
#include "interr.h"
#include "lispregs.h"
#include "validate.h"
#include "thread.h"

/* The host preopens the whole file system and passes its working
 * directory as PWD; wasi-libc's emulated working directory (chdir) makes
 * relative paths resolve there, as on any other target. */
void os_init()
{
    const char *pwd = getenv("PWD");
    if (pwd && *pwd && chdir(pwd) != 0)
        fprintf(stderr, "sbcl-wasm: chdir(%s) failed\n", pwd);
}

/* The fixed spaces are addresses in this module's linear memory; they
 * are "allocated" by growing the memory (wasi-mman.c), which can not
 * fail for reasons of address space layout. */
/* The runtime's own path (SB-EXT:*RUNTIME-PATHNAME*, and what RUN-PROGRAM
 * runs for a child SBCL): argv[0], made absolute with the working
 * directory the host passes as PWD (os_init). runtime.c's fallback
 * would call realpath, which wasi-libc does not provide. */
static char *runtime_path;
int os_preinit(char *argv[], char *envp[])
{
    const char *argv0 = argv && argv[0] ? argv[0] : "sbcl.wasm";
    const char *pwd = getenv("PWD");
    if (argv0[0] == '/' || !pwd || !*pwd) {
        runtime_path = strdup(argv0);
    } else {
        size_t n = strlen(pwd) + strlen(argv0) + 2;
        runtime_path = malloc(n);
        snprintf(runtime_path, n, "%s/%s", pwd, argv0);
    }
    return 0;
}

void os_install_interrupt_handlers(void) {}

char *os_get_runtime_executable_path() { return runtime_path; }

int arch_os_thread_init(struct thread *thread) { return 1; }
int arch_os_thread_cleanup(struct thread *thread) { return 1; }

os_context_register_t *os_context_register_addr(os_context_t *context, int offset)
{
    return &context->regs[offset];
}

os_context_register_t *os_context_lr_addr(os_context_t *context)
{
    return os_context_register_addr(context, reg_RA);
}


os_context_register_t *os_context_sp_addr(os_context_t *context)
{
    return os_context_register_addr(context, reg_CSP);
}

os_context_register_t *os_context_fp_addr(os_context_t *context)
{
    return os_context_register_addr(context, reg_CFP);
}


sigset_t *os_context_sigmask_addr(os_context_t *context)
{
    static sigset_t none;
    return &none;
}

void os_restore_fp_control(os_context_t *context) {}

os_context_register_t *os_context_float_register_addr(os_context_t *context, int offset)
{
    return (os_context_register_t*)((char*)lisp_register_area
                                    + LISP_REGISTER_AREA_FLOATS + 8 * offset);
}

void os_flush_icache(os_vm_address_t address, os_vm_size_t length) {}

/* one thread, one id */
int sb_GetTID(void) { return 1; }

int _stat(const char *pathname, struct stat *sb) { return stat(pathname, sb); }
int _lstat(const char *pathname, struct stat *sb) { return lstat(pathname, sb); }
int _fstat(int fd, struct stat *sb) { return fstat(fd, sb); }
