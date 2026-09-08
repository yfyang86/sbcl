/*
 * WebAssembly/WASI memory management: one linear memory, grown on
 * demand, never protected, never shrunk (doc/wasm-port/02-design.md,
 * 2.3). A space at a fixed address is made available by growing the
 * memory past its end; a movable allocation comes from malloc.
 *
 * This software is part of the SBCL system. See the README file for
 * more information.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "genesis/sbcl.h"
#include "os.h"
#include "interr.h"
#include "validate.h"

#define WASM_PAGE_BYTES 65536

static int ensure_linear_memory(uintptr_t end)
{
    uintptr_t current = (uintptr_t)__builtin_wasm_memory_size(0) * WASM_PAGE_BYTES;
    if (end <= current) return 1;
    uintptr_t pages = (end - current + WASM_PAGE_BYTES - 1) / WASM_PAGE_BYTES;
    if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) {
        fprintf(stderr, "memory.grow(%zu pages) failed: linear memory is %zu bytes,"
                " %zu wanted\n", (size_t)pages, (size_t)current, (size_t)end);
        return 0;
    }
    return 1;
}

os_vm_address_t
os_alloc_gc_space(int space_id, int attributes, os_vm_address_t addr, os_vm_size_t len)
{
    if (addr) {
        if (!ensure_linear_memory((uintptr_t)addr + len)) return 0;
        /* fresh pages are zero; a re-used range is zeroed by the caller
         * (coreparse loads over it, GC zeroes what it frees) */
        return addr;
    }
    /* movable: from the C heap, page aligned and zeroed */
    void *p = aligned_alloc(WASM_PAGE_BYTES,
                            (len + WASM_PAGE_BYTES - 1) & ~(size_t)(WASM_PAGE_BYTES - 1));
    if (!p) {
        fprintf(stderr, "os_alloc_gc_space(%d,%d,%p,%zu): out of memory\n",
                space_id, attributes, addr, (size_t)len);
        return 0;
    }
    memset(p, 0, len);
    return p;
}

void os_invalidate(os_vm_address_t addr, os_vm_size_t len) {}

/* Linear memory has one protection: none of the guard pages, write
 * barriers or read-only spaces built on mprotect exist here
 * (ENABLE_PAGE_PROTECTION is 0 in os.h). */
void os_protect(os_vm_address_t address, os_vm_size_t length, os_vm_prot_t prot) {}

void os_zero(os_vm_address_t addr, os_vm_size_t length)
{
    memset(addr, 0, length);
}
