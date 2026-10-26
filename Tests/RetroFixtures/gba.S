/* SPDX-License-Identifier: CC0-1.0
 * Original test program: red screen, blue while A is held. No game assets/BIOS.
 */
.syntax unified
.cpu arm7tdmi
.arm
.global _start
_start:
    b start
    .org 0xc0
start:
    ldr r0, =0x0e000000
    ldrb r1, [r0]
    cmp r1, #0xff
    moveq r1, #0x41
    add r1, r1, #1
    strb r1, [r0]
    ldr r0, =0x04000000
    ldr r1, =0x0403
    strh r1, [r0]
again:
    ldr r3, =0x04000130
    ldrh r4, [r3]
    /* B changes the hardware PWM sample clock: real cores must notify the
     * frontend when switching between 32768 and 65536 Hz during gameplay. */
    tst r4, #2
    ldreq r5, =0x4200
    ldrne r5, =0x0200
    ldr r6, =0x04000088
    strh r5, [r6]
    tst r4, #1
    moveq r1, #0x7c00
    movne r1, #0x001f
    ldr r0, =0x06000000
    ldr r2, =38400
fill:
    strh r1, [r0], #2
    subs r2, r2, #1
    bne fill
    b again
    .ltorg
