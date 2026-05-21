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
@ abort() — libgcc's AEABI helpers (e.g. __aeabi_ldivmod, the
@ idiv0 trap) call into libc's `abort()` on undefined or
@ overflow conditions.  Bare-metal has no libc, so provide a
@ matching C-ABI symbol that exits via semihosting.  Same SVC
@ shape as SemihostExit but the exit code is hardcoded to 134
@ (SIGABRT convention).
@ ============================================================
	.globl abort
	.type  abort, %function
abort:
	mov     r0, #134        @ exit_status = SIGABRT
	push    {r0}            @ stack: [exit_status]
	movw    r0, #0x0026
	movt    r0, #0x0002     @ r0 = 0x00020026 (ADP_Stopped_ApplicationExit)
	push    {r0}            @ stack: [reason, exit_status]
	mov     r1, sp          @ r1 = &{reason, exit_status}
	mov     r0, #0x20       @ SYS_EXIT_EXTENDED
	svc     #0x123456
	@ Should not return.  Defensive spin if the host doesn't
	@ honor SYS_EXIT_EXTENDED.
1:	b       1b
	.size   abort, . - abort

@ ============================================================
@ bn_semihost__SemihostWriteChar(c char) — write one byte to the
@ debug console via SYS_WRITEC.  pkg/bootstrap.Write loops over
@ the buffer calling this for each byte.  Cheaper than SYS_WRITE0
@ (which would need a null-terminated copy) or SYS_WRITE (which
@ would need to open a "console" file handle first).
@ ============================================================
	.globl bn_semihost__SemihostWriteChar
	.type  bn_semihost__SemihostWriteChar, %function
bn_semihost__SemihostWriteChar:
	@ r0 (param) holds the byte to write — AAPCS zero-extends
	@ a `char` arg into the full 32-bit register.
	push    {r0}            @ stack: [byte]
	mov     r1, sp          @ r1 = &byte (SYS_WRITEC takes a pointer)
	mov     r0, #0x03       @ SYS_WRITEC
	svc     #0x123456
	add     sp, sp, #4      @ pop the byte we pushed
	bx      lr
	.size   bn_semihost__SemihostWriteChar, . - bn_semihost__SemihostWriteChar

@ ============================================================
@ bn_semihost__SemihostExit(code int) — exit the program with
@ the given exit code via SYS_EXIT_EXTENDED.  Does not return.
@
@ Per the semihosting ABI, SYS_EXIT_EXTENDED takes a {reason,
@ exit_status} parameter block.  reason = 0x20026 = ADP_Stopped_
@ ApplicationExit signals a clean application exit (vs a fault).
@ ============================================================
	.globl bn_semihost__SemihostExit
	.type  bn_semihost__SemihostExit, %function
bn_semihost__SemihostExit:
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
	.size   bn_semihost__SemihostExit, . - bn_semihost__SemihostExit
