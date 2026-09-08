#include "interr.h"
#include <stdio.h>

#ifdef LISP_FEATURE_WASM
/* wasi-libc's start code calls the two-argument main (which clang renames
 * to __main_argc_argv); a three-argument or weak main is not found and
 * links as an undefined stub, leaving the runtime out of the module. */
extern char **environ;
int main(int argc, char *argv[])
{
    extern int initialize_lisp(int argc, char *argv[], char *envp[]);
    initialize_lisp(argc, argv, environ);
    lose("unexpected return from initial thread in main()");
    return 0;
}
#else
int
#if !(defined LISP_FEATURE_WIN32 && !defined __clang__)
__attribute__((weak))
#endif
main(int argc, char *argv[], char *envp[])
{
    extern int initialize_lisp(int argc, char *argv[], char *envp[]);
#ifdef TRACE_MMAP_SYSCALLS
    extern FILE* mmgr_debug_logfile;
    mmgr_debug_logfile = fopen("mman.log", "w");
#endif
    initialize_lisp(argc, argv, envp);
    lose("unexpected return from initial thread in main()");
    return 0;
}
#endif
