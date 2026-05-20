@ ARM32 bare-metal crt0 for the v1 arm32-baremetal target.
@ Reset vector → stack setup → jump into Binate.
@
@ Tuned for QEMU's `virt` machine running ARMv7-A in ARM mode:
@   - RAM starts at 0x40000000.
@   - The linker script (baremetal.ld) places .text at the RAM
@     base and .bss / stack in the same region.
@   - Stack grows downward from `_stack_top`, defined by the
@     linker script.
@
@ `bn_entry` is the synthetic Binate function bnc emits for every
@ executable (`<main>.__entry`).  It runs per-package var
@ initializers and then calls user `main`.

	.syntax unified
	.arm

	.section .text.startup, "ax"
	.globl _start
	.type  _start, %function
_start:
	@ Set up the stack — _stack_top is defined by the linker
	@ script at the high end of RAM.
	ldr     sp, =_stack_top

	@ Hand control to Binate.  bn_entry runs init dispatchers
	@ and then calls main; returns when main returns.
	bl      bn_entry

	@ If main returns, exit cleanly via semihosting.  Pass r0
	@ through as the exit code (bn_entry returns void in current
	@ shape, so this is 0 in practice; a future
	@ `func main() int` would route a status through here).
	mov     r0, #0
	bl      bn_semihost__SemihostExit

	@ Defensive halt in case SemihostExit ever returns.
1:	b       1b
	.size   _start, . - _start
