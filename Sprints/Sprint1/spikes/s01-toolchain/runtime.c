/* S0.1: a stand-in for the SBCL C runtime. Exports its memory and its
 * indirect function table, and calls through the table the way
 * call_into_lisp would. Built with wasi-sdk clang. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

typedef int32_t (*lispfn)(int32_t);

__attribute__((export_name("call_slot")))
int32_t call_slot(int32_t slot, int32_t arg) {
    /* clang lowers a call through a function pointer to call_indirect on
     * __indirect_function_table; the "pointer" is the table index. */
    lispfn f = (lispfn)(uintptr_t)slot;
    return f(arg);
}

__attribute__((export_name("alloc_words")))
void *alloc_words(int32_t n) { return calloc(n, 4); }

int main(void) {
    printf("hello from the SBCL wasm runtime stand-in (wasi-sdk)\n");
    printf("sizeof(void*)=%zu sizeof(long)=%zu\n", sizeof(void *), sizeof(long));
    return 0;
}
