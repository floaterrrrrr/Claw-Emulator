/* SPDX-License-Identifier: CC0-1.0
 * Original direct-boot DS test program: a red VRAM framebuffer.
 */
.syntax unified
.cpu arm946e-s
.arm
.global _start
_start:
    ldr r0, =0x04000304
    ldr r1, =0x820f
    strh r1, [r0]
    ldr r0, =0x04000240
    mov r1, #0x80
    strb r1, [r0]
    ldr r0, =0x04000000
    mov r1, #0x20000
    str r1, [r0]
    ldr r0, =0x06800000
    mov r1, #31
    mov r2, #0x10000
fill:
    strh r1, [r0], #2
    subs r2, r2, #1
    bne fill
hold:
    b hold
    .ltorg
