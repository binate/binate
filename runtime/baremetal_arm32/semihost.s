// ARM32 bare-metal semihosting helpers for the v1 arm32-baremetal
// target.  Linked alongside Binate-compiled .o files when bnc is
// invoked with `--target arm32-baremetal`.
//
// Written in the subset of ARM assembly that Binate's own assembler
// (bnas, pkg/binate/asm) accepts and assembled with `bnas -arch arm32`
// by bnc at link time (not fed to clang): `//` line comments,
// `.section text`, `.global`, dot-less local labels, UAL mnemonics.
//
// Semihosting ABI (ARM EABI / QEMU virt machine):
//   - r0 = operation number (e.g. 0x20 = SYS_EXIT_EXTENDED,
//                            0x03 = SYS_WRITEC)
//   - r1 = parameter block address (or single value)
//   - svc #0x123456 issues the host call (ARM mode; Thumb mode
//                                          uses 0xab)
// See:
//   https://github.com/ARM-software/abi-aa/blob/main/semihosting/semihosting.rst
//
// All routines here use the ARM (not Thumb) instruction set.  Soft-
// float ABI — no VFP / NEON instructions.

	.arch arm32

	.section text

// ============================================================
// Stubs for the libc / libgcc symbols clang emits implicitly:
//   memcpy, memset, memmove, memcmp.
// The IR for any Binate struct-by-value copy or aggregate
// initialization lowers to one of these (LLVM's memcpy intrinsic
// resolves to libc's memcpy at link time).  We don't have libc
// on bare-metal, so provide byte-at-a-time impls here.  Cheap
// and obviously-correct; replaceable with arm-tuned word-copy
// loops once perf matters.
// ============================================================
	.global memcpy
memcpy:
	// r0 = dst (preserved on return), r1 = src, r2 = len
	push    {r0, r4}        // save dst for return; r4 scratch
	cmp     r2, #0
	beq     memcpy_done
memcpy_loop:
	ldrb    r4, [r1], #1
	strb    r4, [r0], #1
	subs    r2, r2, #1
	bne     memcpy_loop
memcpy_done:
	pop     {r0, r4}        // restore original dst into r0
	bx      lr

// memmove: same as memcpy for non-overlapping; for overlap,
// copy backwards when dst > src.  Bare-metal v1 doesn't
// exercise overlap in user code, but compilers sometimes emit
// memmove for type-erased aggregate copies.
	.global memmove
memmove:
	// r0 = dst, r1 = src, r2 = len
	push    {r0, r4}
	cmp     r2, #0
	beq     memmove_done
	cmp     r0, r1
	bls     memmove_fwd     // dst <= src -> forward copy
	// Backward copy: i = len; while (i--) dst[i] = src[i].
	add     r0, r0, r2
	add     r1, r1, r2
memmove_back:
	ldrb    r4, [r1, #-1]!
	strb    r4, [r0, #-1]!
	subs    r2, r2, #1
	bne     memmove_back
	b       memmove_done
memmove_fwd:
	ldrb    r4, [r1], #1    // forward (same as memcpy)
	strb    r4, [r0], #1
	subs    r2, r2, #1
	bne     memmove_fwd
memmove_done:
	pop     {r0, r4}
	bx      lr

	.global memset
memset:
	// r0 = dst (preserved on return), r1 = byte, r2 = len
	push    {r0, r4}
	and     r1, r1, #0xff   // memset takes int but uses low byte
	cmp     r2, #0
	beq     memset_done
memset_loop:
	strb    r1, [r0], #1
	subs    r2, r2, #1
	bne     memset_loop
memset_done:
	pop     {r0, r4}
	bx      lr

	.global memcmp
memcmp:
	// r0 = a, r1 = b, r2 = len; returns r0 = signed-cmp result
	push    {r4, r5}
	mov     r4, #0          // default result = 0 (equal)
	cmp     r2, #0
	beq     memcmp_done
memcmp_loop:
	ldrb    r3, [r0], #1
	ldrb    r5, [r1], #1
	subs    r4, r3, r5
	bne     memcmp_done
	subs    r2, r2, #1
	bne     memcmp_loop
memcmp_done:
	mov     r0, r4
	pop     {r4, r5}
	bx      lr

// ============================================================
// abort() — libgcc's AEABI helpers (e.g. __aeabi_ldivmod, the
// idiv0 trap) call into libc's `abort()` on undefined or
// overflow conditions.  Bare-metal has no libc, so provide a
// matching C-ABI symbol that exits via semihosting.  Same SVC
// shape as SemihostExit but the exit code is hardcoded to 134
// (SIGABRT convention).
// ============================================================
	.global abort
abort:
	mov     r0, #134        // exit_status = SIGABRT
	push    {r0}            // stack: [exit_status]
	movw    r0, #0x0026
	movt    r0, #0x0002     // r0 = 0x00020026 (ADP_Stopped_ApplicationExit)
	push    {r0}            // stack: [reason, exit_status]
	mov     r1, sp          // r1 = &{reason, exit_status}
	mov     r0, #0x20       // SYS_EXIT_EXTENDED
	svc     #0x123456
	// Should not return.  Defensive spin if the host doesn't
	// honor SYS_EXIT_EXTENDED.
abort_spin:
	b       abort_spin

// ============================================================
// semihost.SemihostWriteChar(c char) — write one byte to the debug
// console via SYS_WRITEC.  The bare-metal output sinks (rt's panic
// writer, testing's stdout) loop over a buffer calling this for each
// byte.  Cheaper than SYS_WRITE0 (which would need a null-terminated
// copy) or SYS_WRITE (which would need to open a "console" file handle
// first).  The symbol is the length-prefix mangling of (pkg
// "pkg/semihost", func "SemihostWriteChar").
// ============================================================
	.global bn_F2_3_pkg8_semihost1_17_SemihostWriteChar
bn_F2_3_pkg8_semihost1_17_SemihostWriteChar:
	// r0 (param) holds the byte to write — AAPCS zero-extends
	// a `char` arg into the full 32-bit register.
	push    {r0}            // stack: [byte]
	mov     r1, sp          // r1 = &byte (SYS_WRITEC takes a pointer)
	mov     r0, #0x03       // SYS_WRITEC
	svc     #0x123456
	add     sp, sp, #4      // pop the byte we pushed
	bx      lr

// ============================================================
// semihost.SemihostExit(code int) — exit the program with the given
// exit code via SYS_EXIT_EXTENDED.  Does not return.  The symbol is the
// length-prefix mangling of (pkg "pkg/semihost", func "SemihostExit").
//
// Per the semihosting ABI, SYS_EXIT_EXTENDED takes a {reason,
// exit_status} parameter block.  reason = 0x20026 = ADP_Stopped_
// ApplicationExit signals a clean application exit (vs a fault).
// ============================================================
	.global bn_F2_3_pkg8_semihost1_12_SemihostExit
bn_F2_3_pkg8_semihost1_12_SemihostExit:
	// r0 (param) holds the exit code on entry.
	push    {r0}            // stack: [exit_status]
	movw    r0, #0x0026
	movt    r0, #0x0002     // r0 = 0x00020026 (ADP_Stopped_ApplicationExit)
	push    {r0}            // stack: [reason, exit_status]
	mov     r1, sp          // r1 = &{reason, exit_status}
	mov     r0, #0x20       // SYS_EXIT_EXTENDED
	svc     #0x123456
	// Should not return.  Spin defensively in case the host doesn't
	// honor SYS_EXIT_EXTENDED — gives the program a stable halt point.
sh_exit_spin:
	b       sh_exit_spin

// ============================================================
// semihost.SemihostGetCmdline(buf *uint8, cap int) int — fetch the host
// command line via SYS_GET_CMDLINE (0x15).  The parameter block is
// {buffer, length}: on entry length = buffer capacity, on return length =
// the actual command-line length and the buffer holds it (NUL-terminated).
// r0 = 0 on success, -1 on failure.  On QEMU's virt machine the command
// line is the `-append` string.  Returns the length, or -1 on failure.
// ============================================================
	.global bn_F2_3_pkg8_semihost1_18_SemihostGetCmdline
bn_F2_3_pkg8_semihost1_18_SemihostGetCmdline:
	// r0 = buf ptr, r1 = cap (bytes).  Build the {ptr, len} block on the stack.
	push    {r0, r1}        // stack: [ptr, len]
	mov     r1, sp          // r1 = &{ptr, len}
	mov     r0, #0x15       // SYS_GET_CMDLINE
	svc     #0x123456
	cmp     r0, #0
	bne     sh_cmdline_fail
	ldr     r0, [sp, #4]    // success: return the updated length field
	add     sp, sp, #8
	bx      lr
sh_cmdline_fail:
	movw    r0, #0xffff
	movt    r0, #0xffff     // r0 = 0xffffffff = -1
	add     sp, sp, #8
	bx      lr
