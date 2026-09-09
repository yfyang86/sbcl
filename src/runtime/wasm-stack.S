# The C shadow stack pointer (wasi-libc's __stack_pointer global), for the
# Lisp side: a non-local exit through C frames (an error signalled from
# compiled code enters Lisp from the runtime's internal_error) abandons
# those frames without their epilogues, so the catch point restores the
# pointer it saved when its block was made (MAKE-UNWIND-BLOCK, nlx.lisp;
# EMIT-NLX-HANDLER, func-asm.lisp).
        .globaltype __stack_pointer, i32
        .text
        .globl c_stack_save
        .type c_stack_save,@function
c_stack_save:
        .functype c_stack_save () -> (i32)
        global.get __stack_pointer
        end_function

        .globl c_stack_restore
        .type c_stack_restore,@function
c_stack_restore:
        .functype c_stack_restore (i32) -> ()
        local.get 0
        global.set __stack_pointer
        end_function
