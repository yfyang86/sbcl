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
#include <unistd.h>

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
#include "genesis/sap.h"
#include "code.h"
#include "gc.h"
#include "pseudo-atomic.h"
extern os_vm_size_t bytes_allocated;

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
    return (unsigned char*)context->error;
}

/* the Lisp side's view of the same block */
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
void arch_set_pseudo_atomic_interrupted(struct thread *thread) { set_pseudo_atomic_interrupted(thread); }
void arch_clear_pseudo_atomic_interrupted(struct thread *thread) { clear_pseudo_atomic_interrupted(thread); }

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

extern unsigned char *gc_card_mark;
extern sword_t gc_card_table_mask;

lispobj call_into_lisp(lispobj fun, lispobj *args, int nargs)
{
    struct thread *th = get_sb_vm_thread();
    uint32_t *r = lisp_register_area;
    /* the store barrier's view of the card table (constant after startup) */
    *(uint32_t*)((char*)r + LISP_REGISTER_AREA_CARD_TABLE) = (uint32_t)(uintptr_t)gc_card_mark;
    *(uint32_t*)((char*)r + LISP_REGISTER_AREA_CARD_MASK) = (uint32_t)gc_card_table_mask;
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
extern int internal_errors_enabled;
extern void bind_variable(lispobj symbol, lispobj value, void *th);
extern void unbind(void *th);

static void describe_wasm_internal_error(os_context_t *context)
{
    int i;
    fprintf(stderr, "Lisp internal error: trap kind %d, error code %d, %d argument(s):",
            context->error[0], context->error[1], context->error[2]);
    for (i = 0; i < (int)context->error[2] && i < 16; i++)
        fprintf(stderr, " %#x", context->error[3 + i]);
    fprintf(stderr, "\n  registers:");
    for (i = 0; i <= reg_RA; i++)
        fprintf(stderr, "%s%s %#x", (i % 6 == 0) ? "\n   " : " ",
                lisp_register_names[i], context->regs[i]);
    fprintf(stderr, "\n");
    /* the callee of a named call has its fdefn in LEXENV */
    lispobj lexenv = context->regs[reg_LEXENV];
    if (lowtag_of(lexenv) == OTHER_POINTER_LOWTAG
        && widetag_of(native_pointer(lexenv)) == FDEFN_WIDETAG) {
        fprintf(stderr, "  LEXENV is the fdefn of ");
        wasm_print_name(FDEFN(lexenv)->name);
        fprintf(stderr, "\n");
    }
    fflush(stderr);
}

/* The internal_error import (EMIT-ERROR-BREAK, macros.lisp): compiled
 * code has stored the SC+OFFSET words of the arguments into the register
 * area's error-argument area. This is the whole of interrupt_internal_error
 * for this target: snapshot the registers into a context, make it the
 * current interrupt context (so that the debugger's FIND-INTERRUPTED-FRAME
 * and the register accessors see the erring frame) and call the Lisp
 * handler INTERNAL-ERROR, which signals the condition. The handler
 * leaves by a non-local exit through this frame; errors are not
 * continuable here (the calling code follows the call with unreachable),
 * so a return is fatal. */
__attribute__((export_name("internal_error")))
void wasm_internal_error(int32_t kind, int32_t code, int32_t nargs)
{
    struct thread *th = get_sb_vm_thread();
    os_context_t context;
    uint32_t *args = (uint32_t*)((char*)lisp_register_area + LISP_REGISTER_AREA_ERROR_ARGS);
    int i;
    memcpy(context.regs, lisp_register_area, sizeof context.regs);
    context.error[0] = kind;
    context.error[1] = code;
    context.error[2] = nargs;
    for (i = 0; i < nargs && i < 16; i++) context.error[3 + i] = args[i];
    /* the "pc": the start of the current code object's instructions */
    lispobj codeobj = lisp_register_area[reg_CODE];
    context.pc = 0;
    if (lowtag_of(codeobj) == OTHER_POINTER_LOWTAG
        && widetag_of(native_pointer(codeobj)) == CODE_HEADER_WIDETAG) {
        struct code *c = (struct code*)native_pointer(codeobj);
        context.pc = (uint32_t)(uintptr_t)((lispobj*)c + code_header_words(c));
    }
    if (!internal_errors_enabled) {
        describe_wasm_internal_error(&context);
        lose("internal error too early in init, can't recover");
    }
    if (getenv("SBCL_WASM_TRACE_ERRORS"))
        describe_wasm_internal_error(&context);
    int index = fixnum_value(read_TLS(FREE_INTERRUPT_CONTEXT_INDEX, th));
    if (index >= MAX_INTERRUPTS)
        lose("maximum interrupt nesting depth (%d) exceeded", MAX_INTERRUPTS);
    /* a dynamic binding: the non-local exit out of the handler unbinds it */
    bind_variable(FREE_INTERRUPT_CONTEXT_INDEX, make_fixnum(index + 1), th);
    nth_interrupt_context(index, th) = &context;
    DX_ALLOC_SAP(context_sap, &context);
    funcall2(StaticSymbolFunction(INTERNAL_ERROR), context_sap, NIL);
    nth_interrupt_context(index, th) = NULL;
    unbind(th);
    describe_wasm_internal_error(&context);
    lose("the internal error handler returned: continuable errors are not supported on this target");
}

/* Called by every XEP when the interrupt-pending word of the register
 * area is nonzero: 1 is an interrupt request (from the host's Ctrl-C),
 * 2 (SBCL_WASM_TRACE_ENTRIES) makes this trace every function entry:
 * the callee's table index (LEXENV is its fdefn for a named call, else
 * the function object) and the frame registers. Decode the indices with
 * Sprints/Sprint7/coreindex.py --annotate. */
static uint32_t *interrupt_pending_word(void)
{
    return (uint32_t*)((char*)lisp_register_area + LISP_REGISTER_AREA_INTERRUPT_PENDING);
}
__attribute__((export_name("pending_interrupt")))
void wasm_pending_interrupt(void)
{
    uint32_t *word = interrupt_pending_word();
    struct thread *th = get_sb_vm_thread();
    if (*word & WASM_PENDING_TRACE) {
        lispobj lexenv = lisp_register_area[reg_LEXENV];
        fprintf(stderr, "; enter");
        if (lowtag_of(lexenv) == OTHER_POINTER_LOWTAG
            && widetag_of(native_pointer(lexenv)) == FDEFN_WIDETAG) {
            fprintf(stderr, " ");
            wasm_print_name(FDEFN(lexenv)->name);
        } else if (lowtag_of(lexenv) == FUN_POINTER_LOWTAG) {
            lispobj dummy;
            fprintf(stderr, " table %u", (unsigned)function_entry_index(lexenv, &dummy));
        } else {
            fprintf(stderr, " lexenv %#x", (unsigned)lexenv);
        }
        fprintf(stderr, ": NARGS %d CFP %#x CSP %#x OCFP %#x A0 %#x A1 %#x\n",
                (int)fixnum_value(lisp_register_area[reg_NARGS]),
                lisp_register_area[reg_CFP], lisp_register_area[reg_CSP],
                lisp_register_area[reg_OCFP], lisp_register_area[reg_A0],
                lisp_register_area[reg_A1]);
    }
    /* A GC is pending (trigger_gc, gengc.inc, through
     * set_pseudo_atomic_interrupted): a safe point is where it runs, as
     * the end of a pseudo-atomic section is elsewhere; every live Lisp
     * value is in the register area or on the control stack here. While
     * *GC-INHIBIT* is set the bit stays, so that the end of the
     * WITHOUT-GCING (which calls receive-pending-interrupt) runs it. */
    if (*word & WASM_PENDING_GC) {
        if (read_TLS(GC_INHIBIT, th) == NIL) {
            *word &= ~(uint32_t)WASM_PENDING_GC;
            if (read_TLS(GC_PENDING, th) == LISP_T) {
                if (getenv("SBCL_WASM_VERBOSE"))
                    fprintf(stderr, "sbcl-wasm: gc at a safe point (%zu bytes allocated)\n",
                            (size_t)bytes_allocated);
                maybe_gc(0);
            }
        }
    }
    if (*word & WASM_PENDING_INTERRUPT) {
        *word &= ~(uint32_t)WASM_PENDING_INTERRUPT;
        fprintf(stderr, "; interrupt request seen at a safe point (delivery to Lisp is not implemented yet)\n");
    }
}

/* The allocation entry points compiled code calls (alloc.c), wrapped so
 * that SBCL_WASM_TRACE_ALLOC=1 shows the frame registers at every
 * allocation: a cheap way to bracket where a frame pointer goes bad. */
extern lispobj *alloc(sword_t nbytes);
extern lispobj *alloc_list(sword_t nbytes);
static int trace_alloc = -1;
static void trace_allocation(const char *what, sword_t nbytes)
{
    if (trace_alloc < 0) trace_alloc = getenv("SBCL_WASM_TRACE_ALLOC") != 0;
    if (trace_alloc)
        fprintf(stderr, "; %s %ld: CFP %#x CSP %#x OCFP %#x CODE %#x LEXENV %#x A0 %#x A1 %#x A2 %#x A3 %#x\n",
                what, (long)nbytes,
                lisp_register_area[reg_CFP], lisp_register_area[reg_CSP],
                lisp_register_area[reg_OCFP], lisp_register_area[reg_CODE],
                lisp_register_area[reg_LEXENV], lisp_register_area[reg_A0],
                lisp_register_area[reg_A1], lisp_register_area[reg_A2], lisp_register_area[reg_A3]);
}
__attribute__((export_name("alloc")))
lispobj *wasm_alloc(sword_t nbytes)
{
    trace_allocation("alloc", nbytes);
    lispobj *result = alloc(nbytes);
    trace_allocation("  after alloc", nbytes);
    return result;
}
__attribute__((export_name("alloc_list")))
lispobj *wasm_alloc_list(sword_t nbytes)
{
    trace_allocation("alloc_list", nbytes);
    lispobj *result = alloc_list(nbytes);
    trace_allocation("  after alloc_list", nbytes);
    return result;
}

/* exit and _exit with the int result SB-UNIX's SYSCALL declares (the
 * linkage table maps the names here, tools-for-build/wasm-linkage-table.sh) */
int wasm_exit_int(int code) { exit(code); return 0; }
int wasm__exit_int(int code) { _exit(code); return 0; }

/*** the core module (2.2) ***/

__attribute__((import_module("sbcl_host"), import_name("instantiate")))
int32_t sbcl_host_instantiate(const void *bytes, int32_t length,
                              void *register_area, int32_t table_base);

/* The module holding the core's functions lives next to the core file:
 * "foo.core" -> "foo-core.wasm". The host instantiates it against this
 * module's memory and table, with the register area as its thread. */
/* Modules loaded at run time (WASM-INSTALL-CODE in wasm-vm.lisp) */
int wasm_instantiate_module(const void *bytes, int32_t length, uint32_t table_base)
{
    return sbcl_host_instantiate(bytes, length, lisp_register_area, table_base);
}

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
    /* The modules code loaded at run time made (WASM-INSTALL-CODE): a saved
     * core keeps them in *WASM-LOADED-MODULES* as (table-base . bytes),
     * newest first; instantiate them again, oldest first, at their table
     * ranges. In a cold core the symbol is not yet bound. */
    {
        lispobj list = SymbolValue(WASM_LOADED_MODULES, 0);
        if (lowtag_of(list) == LIST_POINTER_LOWTAG && list != NIL) {
            int n = 0, i;
            lispobj l;
            for (l = list; l != NIL; l = CONS(l)->cdr) n++;
            lispobj *entries = checked_malloc(n * sizeof(lispobj));
            for (i = n - 1, l = list; i >= 0; i--, l = CONS(l)->cdr) entries[i] = CONS(l)->car;
            if (!lisp_startup_options.noinform)
                fprintf(stderr, "; instantiating %d saved modules\n", n);
            for (i = 0; i < n; i++) {
                struct cons *entry = CONS(entries[i]);
                struct vector *v = VECTOR(entry->cdr);
                if (!sbcl_host_instantiate((char*)v->data, (int32_t)vector_len(v), lisp_register_area,
                                           (uint32_t)fixnum_value(entry->car)))
                    lose("the host could not instantiate saved module %d", i);
            }
            free(entries);
        }
    }
    if (getenv("SBCL_WASM_TRACE_ENTRIES"))
        *interrupt_pending_word() |= WASM_PENDING_TRACE;
    /* SBCL_WASM_VERIFY_GC=1: the collector's heap verifier runs before and
     * after every collection and reports each pointer to a stale object */
    if (getenv("SBCL_WASM_VERIFY_GC")) {
        extern generation_index_t verify_gens;
        extern int pre_verify_gen_0;
        verify_gens = 0;
        pre_verify_gen_0 = 1;
    }
    free(bytes);
    free(path);
}

/* The monitor (ldb) is not built on this target. */
void ldb_monitor(void)
{
    fprintf(stderr, "ldb is not available on WebAssembly\n");
    exit(1);
}
