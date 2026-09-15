.text
.align 2

.globl _EB137CallSwiftSelf0
_EB137CallSwiftSelf0:
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    blr x1
    ldp x20, x30, [sp], #16
    ret
