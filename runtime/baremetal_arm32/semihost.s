@ ARM32 bare-metal semihosting helpers for the v1 arm32-baremetal
@ target.  Linked alongside Binate-compiled .o files when bnc is
@ invoked with `--target arm32-baremetal`.
@
@ Semihosting ABI (ARM EABI / QEMU virt machine):
@   - r0 = operation number (e.g. 0x20 = SYS_EXIT_EXTENDED,
@                            0x05 = SYS_WRITE)
@   - r1 = parameter block address (or single value)
@   - svc #0x123456 issues the host call (ARM mode; Thumb mode
@                                          uses 0xab)
@ See:
@   https://github.com/ARM-software/abi-aa/blob/main/semihosting/semihosting.rst
@
@ All routines here use the ARM (not Thumb) instruction set.  Soft-
@ float ABI — no VFP / NEON instructions.

	.syntax unified
	.arm

@ ============================================================
@ bn_baremetal__SemihostExit(code int) — exit the program with
@ the given exit code via SYS_EXIT_EXTENDED.  Does not return.
@
@ Per the semihosting ABI, SYS_EXIT_EXTENDED takes a {reason,
@ exit_status} parameter block.  reason = 0x20026 = ADP_Stopped_
@ ApplicationExit signals a clean application exit (vs a fault).
@ ============================================================
	.globl bn_baremetal__SemihostExit
	.type  bn_baremetal__SemihostExit, %function
bn_baremetal__SemihostExit:
	@ r0 (param) holds the exit code on entry.
	push    {r0}            @ stack: [exit_status]
	movw    r0, #0x0026
	movt    r0, #0x0002     @ r0 = 0x00020026 (ADP_Stopped_ApplicationExit)
	push    {r0}            @ stack: [reason, exit_status]
	mov     r1, sp          @ r1 = &{reason, exit_status}
	mov     r0, #0x20       @ SYS_EXIT_EXTENDED
	svc     #0x123456
	@ Should not return.  Spin defensively in case the host doesn't
	@ honor SYS_EXIT_EXTENDED — gives the program a stable halt point.
1:	b       1b
	.size   bn_baremetal__SemihostExit, . - bn_baremetal__SemihostExit
