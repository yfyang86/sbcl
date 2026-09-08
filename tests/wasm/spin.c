/* A WASI program that never returns: exercises the host's deadline
 * (SBCL_WASM_TIMEOUT) and Ctrl-C handling (Sprints/Sprint6/uat.sh). */
#include <stdio.h>
int main(void)
{
    volatile unsigned long n = 0;
    puts("spinning");
    fflush(stdout);
    for (;;) n++;
    return 0;
}
