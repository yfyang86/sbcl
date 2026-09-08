/*
 * WebAssembly: the architecture-dependent runtime support.
 *
 * Compiled Lisp code keeps its registers in a per-thread register area
 * (wasm-lispregs.h) that it reaches through the "thread" global of its
 * module; the runtime hands the area's address to the host when a
 * module is instantiated. A Lisp function is an entry of the shared
 * funcref table, so calling into Lisp is an ordinary C indirect call
 * through the simple-fun's self slot, which holds the table index
 * (doc/wasm-port/02-design.md, 2.2 and 2.4).
 *
 * This software is part of the SBCL system. See the README file for
 * more information.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#include "genesis/sbcl.h"

/* First table index used by the core module's functions; must agree with
 * sb-vm::+core-table-base+ (src/compiler/wasm/parms.lisp). The host checks
 * it against the module's sbcl.core.table custom section. */
#define WASM_CORE_TABLE_BASE 4096
#include "runtime.h"
#include "arch.h"
#include "globals.h"
#include "validate.h"
#include "os.h"
#include "print.h"
#include "lispregs.h"
#include "interrupt.h"
#include "interr.h"
#include "breakpoint.h"
#include "thread.h"
#include "genesis/closure.h"
#include "genesis/cons.h"
#include "genesis/vector.h"
#include "genesis/symbol.h"
#include "genesis/static-symbols.h"

/* The register area of the (only) Lisp thread. Word slots 0..31 are the
 * registers, then the float registers, the internal-error arguments,
 * the unwind target and the float modes (wasm-lispregs.h). */
uint32_t lisp_register_area[LISP_REGISTER_AREA_SIZE / 4]
    __attribute__((aligned(16)));

/* The number stack (non-descriptor stack) of that thread; it grows down
 * from its end. It is separate from the C shadow stack. */
#define NUMBER_STACK_SIZE (1024 * 1024)
static uint32_t number_stack[NUMBER_STACK_SIZE / 4] __attribute__((aligned(16)));

/*** contexts: there are none; these keep the common sources linking ***/

void arch_skip_instruction(os_context_t *context)
{
    lose("arch_skip_instruction: no instruction stream on WebAssembly");
}

unsigned char *arch_internal_error_arguments(os_context_t *context)
{
    return (unsigned char*)((char*)lisp_register_area + LISP_REGISTER_AREA_ERROR_ARGS);
}

/* the Lisp side's view of the same area */
unsigned char *os_context_error_args_addr(os_context_t *context)
{
    return arch_internal_error_arguments(context);
}

/* Labels of the function-end breakpoint code on machine-code backends;
 * referenced by the debugger through the linkage table. There is no such
 * code here (breakpoints are a later sprint); the addresses only have to
 * exist and be distinct. */
unsigned char fun_end_breakpoint_guts[4], fun_end_breakpoint_trap[4], fun_end_breakpoint_end[4];

/* Nothing can interrupt compiled code between its pseudo-atomic
 * sections: there are no signals, and the runtime entry points are
 * called with every register flushed. */
bool arch_pseudo_atomic_atomic(struct thread *thread) { return 1; }
void arch_set_pseudo_atomic_interrupted(struct thread *thread) {}
void arch_clear_pseudo_atomic_interrupted(struct thread *thread) {}

unsigned int arch_install_breakpoint(void *pc)
{
    lose("breakpoints by code patching are not possible on WebAssembly");
    return 0;
}
void arch_remove_breakpoint(void *pc, unsigned int orig_inst) {}
void arch_do_displaced_inst(os_context_t *context, unsigned int orig_inst) {}
void arch_handle_breakpoint(os_context_t *context) {}
void arch_handle_fun_end_breakpoint(os_context_t *context) {}
void arch_handle_single_step_trap(os_context_t *context, int trap) {}
void arch_install_interrupt_handlers(void) {}

/*** the alien linkage table: data words (2.9) ***/

void arch_write_linkage_table_entry(int index, void *target_addr, int datap)
{
    /* a function entry holds the function's table index (which is what
     * a C function pointer is on this target), a data entry the address */
    uint32_t *entry = (uint32_t*)(ALIEN_LINKAGE_SPACE_START
                                  + index * ALIEN_LINKAGE_TABLE_ENTRY_SIZE);
    *entry = (uint32_t)(uintptr_t)target_addr;
}

/*** calling into Lisp ***/

typedef int32_t (*lisp_entry_fn)(void);

/* The table index a function object is entered through: a simple-fun's
 * self slot, or that of the simple-fun a closure or funcallable
 * instance wraps (the same walk as EMIT-FUNCTION-OBJECT-ENTRY). */
static uint32_t function_entry_index(lispobj fun, lispobj *lexenv)
{
    *lexenv = fun;
    for (;;) {
        lispobj *obj = native_pointer(fun);
        int widetag = widetag_of(obj);
        if (widetag == SIMPLE_FUN_WIDETAG)
            return (uint32_t)((struct simple_fun*)obj)->self;
        if (widetag == CLOSURE_WIDETAG || widetag == FUNCALLABLE_INSTANCE_WIDETAG) {
            fun = ((struct closure*)obj)->fun; /* the simple-fun object */
            continue;
        }
        lose("call_into_lisp: %p is not a function (widetag %x)", (void*)fun, widetag);
    }
}

lispobj call_into_lisp(lispobj fun, lispobj *args, int nargs)
{
    struct thread *th = get_sb_vm_thread();
    uint32_t *r = lisp_register_area;
    lispobj lexenv;
    uint32_t index = function_entry_index(fun, &lexenv);
    /* A fresh frame at the current top of the control stack: the first
     * call starts at the stack's base. Arguments beyond the register
     * arguments go in the callee's frame slots, as a full call passes them. */
    uint32_t *frame = r[reg_CSP] ? (uint32_t*)(uintptr_t)r[reg_CSP]
                                 : (uint32_t*)th->control_stack_start;
    int i;
    for (i = 0; i < nargs; i++) {
        if (i < 4) r[reg_A0 + i] = args[i];
        else frame[i] = args[i];
    }
    r[reg_NARGS] = make_fixnum(nargs);
    r[reg_CFP] = (uint32_t)(uintptr_t)frame;
    r[reg_CSP] = (uint32_t)(uintptr_t)(frame + (nargs > 4 ? nargs : 4));
    r[reg_OCFP] = 0;
    r[reg_RA] = 0;
    r[reg_LEXENV] = lexenv;
    r[reg_CODE] = lexenv;
    if (!r[reg_NSP])
        r[reg_NSP] = (uint32_t)(uintptr_t)((char*)number_stack + NUMBER_STACK_SIZE);
    if (getenv("SBCL_WASM_TRACE_CALLS"))
        fprintf(stderr, "; call_into_lisp: function %#x (table index %u), %d argument(s)\n",
                (unsigned)fun, (unsigned)index, nargs);
    int32_t flag = ((lisp_entry_fn)(uintptr_t)index)();
    /* 0: one value in A0; 1: several, the first in A0 (or none) */
    lispobj result = (flag == 0 || r[reg_NARGS] != 0) ? r[reg_A0] : NIL;
    r[reg_CSP] = (uint32_t)(uintptr_t)frame;
    return result;
}

/*** entry points the Lisp modules import from the runtime ***/

/* Print a symbol's name (or a (SETF name) list's) for the reports below. */
static void wasm_print_string(lispobj string)
{
    struct vector *v = VECTOR(string);
    sword_t n = vector_len(v), i;
    if (widetag_of(&v->header) == SIMPLE_BASE_STRING_WIDETAG)
        for (i = 0; i < n; i++) fputc(((char*)v->data)[i], stderr);
    else if (widetag_of(&v->header) == SIMPLE_CHARACTER_STRING_WIDETAG)
        for (i = 0; i < n; i++) {
            uint32_t c = ((uint32_t*)v->data)[i];
            fputc(c < 128 ? (int)c : '?', stderr);
        }
    else
        fprintf(stderr, "#<string %#x>", (unsigned)string);
}
void wasm_print_name(lispobj name)
{
    if (name == NIL) { fprintf(stderr, "NIL"); return; }
    if (lowtag_of(name) == LIST_POINTER_LOWTAG) {
        fprintf(stderr, "(");
        for (; name != NIL && lowtag_of(name) == LIST_POINTER_LOWTAG; name = CONS(name)->cdr) {
            wasm_print_name(CONS(name)->car);
            if (CONS(name)->cdr != NIL) fprintf(stderr, " ");
        }
        fprintf(stderr, ")");
        return;
    }
    if (lowtag_of(name) == OTHER_POINTER_LOWTAG) {
        int widetag = widetag_of(native_pointer(name));
        if (widetag == SYMBOL_WIDETAG) {
            wasm_print_string(SYMBOL(name)->name);
            return;
        }
        if (widetag == SIMPLE_BASE_STRING_WIDETAG || widetag == SIMPLE_CHARACTER_STRING_WIDETAG) {
            fprintf(stderr, "\""); wasm_print_string(name); fprintf(stderr, "\"");
            return;
        }
    }
    fprintf(stderr, "#<object %#x>", (unsigned)name);
}

/* An internal error trap: the SC+offset descriptors of the arguments are
 * in the register area. Until the Lisp error handler is reachable
 * (Sprint 7) this is fatal. */
__attribute__((export_name("internal_error")))
void wasm_internal_error(int32_t kind, int32_t code, int32_t nargs)
{
    uint32_t *args = (uint32_t*)((char*)lisp_register_area + LISP_REGISTER_AREA_ERROR_ARGS);
    fprintf(stderr, "Lisp internal error: trap kind %d, error code %d, %d argument(s):",
            kind, code, nargs);
    int i;
    for (i = 0; i < nargs && i < 16; i++) fprintf(stderr, " %#x", args[i]);
    fprintf(stderr, "\n  registers:");
    for (i = 0; i <= reg_RA; i++)
        fprintf(stderr, "%s%s %#x", (i % 6 == 0) ? "\n   " : " ",
                lisp_register_names[i], lisp_register_area[i]);
    fprintf(stderr, "\n");
    /* the callee of a named call has its fdefn in LEXENV */
    lispobj lexenv = lisp_register_area[reg_LEXENV];
    if (lowtag_of(lexenv) == OTHER_POINTER_LOWTAG
        && widetag_of(native_pointer(lexenv)) == FDEFN_WIDETAG) {
        fprintf(stderr, "  LEXENV is the fdefn of ");
        wasm_print_name(FDEFN(lexenv)->name);
        fprintf(stderr, "\n");
    }
    fprintf(stderr, "fatal error: internal error in compiled Lisp code (trapping for the host's backtrace)\n");
    fflush(stderr);
    /* an unreachable trap rather than exit(): the host then prints the Wasm
     * backtrace through the Lisp frames, with the functions' names */
    __builtin_trap();
}

/* Polled by compiled code; nothing is delivered yet (2.7). */
__attribute__((export_name("pending_interrupt")))
void wasm_pending_interrupt(void) {}

/*** the core module (2.2) ***/

__attribute__((import_module("sbcl_host"), import_name("instantiate")))
int32_t sbcl_host_instantiate(const void *bytes, int32_t length,
                              void *register_area, int32_t table_base);

/* The module holding the core's functions lives next to the core file:
 * "foo.core" -> "foo-core.wasm". The host instantiates it against this
 * module's memory and table, with the register area as its thread. */
void wasm_load_core_module(const char *core_path)
{
    size_t n = strlen(core_path);
    char *path = checked_malloc(n + 16);
    memcpy(path, core_path, n + 1);
    if (n > 5 && !strcmp(path + n - 5, ".core")) path[n - 5] = 0;
    strcat(path, "-core.wasm");
    FILE *f = fopen(path, "rb");
    if (!f) lose("can't open the core module %s", path);
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *bytes = checked_malloc(size);
    if (fread(bytes, 1, size, f) != (size_t)size) lose("can't read the core module %s", path);
    fclose(f);
    if (!lisp_startup_options.noinform)
        fprintf(stderr, "; instantiating %s (%ld bytes)\n", path, size);
    if (!sbcl_host_instantiate(bytes, (int32_t)size, lisp_register_area, WASM_CORE_TABLE_BASE))
        lose("the host could not instantiate the core module %s", path);
    free(bytes);
    free(path);
}

/* The monitor (ldb) is not built on this target. */
void ldb_monitor(void)
{
    fprintf(stderr, "ldb is not available on WebAssembly\n");
    exit(1);
}
