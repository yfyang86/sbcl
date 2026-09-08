/* The mini-runtime for the compiler-only differential tests
 * (doc/wasm-port/05-testing.md, 5.4). Provides linear memory laid out like
 * the real runtime's (the Lisp spaces start at 16 MiB), a thread area, a
 * control stack and a number stack, and the runtime imports a compiled
 * Lisp function may call. It has no collector: alloc bumps a region.
 * Built with wasi-sdk as a reactor; the Rust driver instantiates it and
 * then the module under test against its memory and table. */
#include <stdint.h>
#include <string.h>

#define THREAD_AREA_BYTES 512
#define STACK_WORDS 4096

static uint32_t thread_area[THREAD_AREA_BYTES / 4] __attribute__((aligned(16)));
static uint32_t control_stack[STACK_WORDS] __attribute__((aligned(16)));
static uint32_t number_stack[STACK_WORDS] __attribute__((aligned(16)));

/* an allocation region: 1 MiB, bump pointer */
#define REGION_BYTES (1 << 20)
static uint8_t region[REGION_BYTES] __attribute__((aligned(16)));
static uint32_t region_free;

__attribute__((export_name("thread_area"))) uint32_t thread_area_address(void) {
    return (uint32_t)(uintptr_t)thread_area;
}
__attribute__((export_name("control_stack"))) uint32_t control_stack_address(void) {
    return (uint32_t)(uintptr_t)control_stack;
}
__attribute__((export_name("control_stack_end"))) uint32_t control_stack_end(void) {
    return (uint32_t)(uintptr_t)(control_stack + STACK_WORDS);
}
__attribute__((export_name("number_stack_end"))) uint32_t number_stack_end(void) {
    return (uint32_t)(uintptr_t)(number_stack + STACK_WORDS);
}
__attribute__((export_name("region_start"))) uint32_t region_start(void) {
    return (uint32_t)(uintptr_t)region;
}
__attribute__((export_name("reset"))) void reset(void) {
    memset(thread_area, 0, sizeof thread_area);
    region_free = (uint32_t)(uintptr_t)region;
}

/* runtime imports */
__attribute__((export_name("alloc"))) uint32_t alloc(uint32_t nbytes) {
    uint32_t p = (region_free + 15) & ~15u;
    region_free = p + nbytes;
    return p;
}
__attribute__((export_name("alloc_list"))) uint32_t alloc_list(uint32_t nbytes) {
    return alloc(nbytes);
}
__attribute__((export_name("pending_interrupt"))) void pending_interrupt(void) {}
