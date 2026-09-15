.text
.align 2
.globl _EB144ProjectExistentialAsm
_EB144ProjectExistentialAsm:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x9, x0
    mov x0, x1
    mov x1, x2
    blr x9
    ldp x29, x30, [sp], #16
    ret

.align 2
.globl _EB144CallX20Asm
_EB144CallX20Asm:
    stp x20, x30, [sp, #-16]!
    mov x9, x0
    mov x20, x1
    blr x9
    ldp x20, x30, [sp], #16
    ret

.align 2
.globl _EB149CallX20W0Asm
_EB149CallX20W0Asm:
    stp x20, x30, [sp, #-16]!
    mov x9, x0
    mov x20, x1
    mov w0, w2
    blr x9
    ldp x20, x30, [sp], #16
    ret
