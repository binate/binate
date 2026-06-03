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
@ Stubs for the libc / libgcc symbols clang emits implicitly:
@   memcpy, memset, memmove, memcmp.
@ The IR for any Binate struct-by-value copy or aggregate
@ initialization lowers to one of these (LLVM's memcpy intrinsic
@ resolves to libc's memcpy at link time).  We don't have libc
@ on bare-metal, so provide byte-at-a-time impls here.  Cheap
@ and obviously-correct; replaceable with arm-tuned word-copy
@ loops once perf matters.
@ ============================================================
	.globl memcpy
	.type  memcpy, %function
memcpy:
	@ r0 = dst (preserved on return), r1 = src, r2 = len
	push    {r0, r4}        @ save dst for return; r4 scratch
	cmp     r2, #0
	beq     2f
1:	ldrb    r4, [r1], #1
	strb    r4, [r0], #1
	subs    r2, r2, #1
	bne     1b
2:	pop     {r0, r4}        @ restore original dst into r0
	bx      lr
	.size   memcpy, . - memcpy

@ memmove: same as memcpy for non-overlapping; for overlap,
@ copy backwards when dst > src.  Bare-metal v1 doesn't
@ exercise overlap in user code, but compilers sometimes emit
@ memmove for type-erased aggregate copies.
	.globl memmove
	.type  memmove, %function
memmove:
	@ r0 = dst, r1 = src, r2 = len
	push    {r0, r4}
	cmp     r2, #0
	beq     4f
	cmp     r0, r1
	bls     1f              @ dst <= src → forward copy
	@ Backward copy: i = len; while (i--) dst[i] = src[i].
	add     r0, r0, r2
	add     r1, r1, r2
3:	ldrb    r4, [r1, #-1]!
	strb    r4, [r0, #-1]!
	subs    r2, r2, #1
	bne     3b
	b       4f
1:	ldrb    r4, [r1], #1    @ forward (same as memcpy)
	strb    r4, [r0], #1
	subs    r2, r2, #1
	bne     1b
4:	pop     {r0, r4}
	bx      lr
	.size   memmove, . - memmove

	.globl memset
	.type  memset, %function
memset:
	@ r0 = dst (preserved on return), r1 = byte, r2 = len
	push    {r0, r4}
	and     r1, r1, #0xff   @ memset takes int but uses low byte
	cmp     r2, #0
	beq     2f
1:	strb    r1, [r0], #1
	subs    r2, r2, #1
	bne     1b
2:	pop     {r0, r4}
	bx      lr
	.size   memset, . - memset

@ pkg/codegen emits direct `call void @bn_pkg__builtins__libc__Memcpy(...)`
@ for string-to-managed-chars rodata copies (emit_strings.bn).
@ Bare-metal has no pkg/builtins/libc impl, so alias the
@ bn_pkg__builtins__libc__Memcpy / Memset / Malloc / Calloc / Free /
@ Exit symbols to the C-ABI / Binate equivalents we already provide.
@ Signature shapes match — Binate's `int` on arm32 = i32 = size_t, and
@ libc Memcpy / Memset return void but memcpy / memset return
@ void* (the dst); the codegen-emitted call sites discard the
@ return, so the ABI mismatch is benign.
@
@ The OLD `bn_pkg__libc__*` names are also defined (aliasing to the
@ NEW symbols) so BUILDER bnc-<=0.0.6's compiled-in codegen — which
@ emits the OLD literal — still links.  Remove the OLD names once
@ BUILDER_VERSION is on a release that emits the NEW names natively.
	.globl bn_pkg__builtins__libc__Memcpy
	.type  bn_pkg__builtins__libc__Memcpy, %function
	.globl bn_pkg__libc__Memcpy
	.type  bn_pkg__libc__Memcpy, %function
bn_pkg__builtins__libc__Memcpy:
bn_pkg__libc__Memcpy:
	b       memcpy
	.size   bn_pkg__builtins__libc__Memcpy, . - bn_pkg__builtins__libc__Memcpy
	.size   bn_pkg__libc__Memcpy, . - bn_pkg__libc__Memcpy

	.globl bn_pkg__builtins__libc__Memset
	.type  bn_pkg__builtins__libc__Memset, %function
	.globl bn_pkg__libc__Memset
	.type  bn_pkg__libc__Memset, %function
bn_pkg__builtins__libc__Memset:
bn_pkg__libc__Memset:
	b       memset
	.size   bn_pkg__builtins__libc__Memset, . - bn_pkg__builtins__libc__Memset
	.size   bn_pkg__libc__Memset, . - bn_pkg__libc__Memset

	.globl memcmp
	.type  memcmp, %function
memcmp:
	@ r0 = a, r1 = b, r2 = len; returns r0 = signed-cmp result
	push    {r4, r5}
	mov     r4, #0          @ default result = 0 (equal)
	cmp     r2, #0
	beq     2f
1:	ldrb    r3, [r0], #1
	ldrb    r5, [r1], #1
	subs    r4, r3, r5
	bne     2f
	subs    r2, r2, #1
	bne     1b
2:	mov     r0, r4
	pop     {r4, r5}
	bx      lr
	.size   memcmp, . - memcmp

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
@ bn_pkg__semihost__SemihostWriteChar(c char) — write one byte to the
@ debug console via SYS_WRITEC.  pkg/builtins/bootstrap.Write loops over
@ the buffer calling this for each byte.  Cheaper than SYS_WRITE0
@ (which would need a null-terminated copy) or SYS_WRITE (which
@ would need to open a "console" file handle first).
@ ============================================================
	.globl bn_pkg__semihost__SemihostWriteChar
	.type  bn_pkg__semihost__SemihostWriteChar, %function
bn_pkg__semihost__SemihostWriteChar:
	@ r0 (param) holds the byte to write — AAPCS zero-extends
	@ a `char` arg into the full 32-bit register.
	push    {r0}            @ stack: [byte]
	mov     r1, sp          @ r1 = &byte (SYS_WRITEC takes a pointer)
	mov     r0, #0x03       @ SYS_WRITEC
	svc     #0x123456
	add     sp, sp, #4      @ pop the byte we pushed
	bx      lr
	.size   bn_pkg__semihost__SemihostWriteChar, . - bn_pkg__semihost__SemihostWriteChar

@ ============================================================
@ bn_pkg__semihost__SemihostExit(code int) — exit the program with
@ the given exit code via SYS_EXIT_EXTENDED.  Does not return.
@
@ Per the semihosting ABI, SYS_EXIT_EXTENDED takes a {reason,
@ exit_status} parameter block.  reason = 0x20026 = ADP_Stopped_
@ ApplicationExit signals a clean application exit (vs a fault).
@ ============================================================
	.globl bn_pkg__semihost__SemihostExit
	.type  bn_pkg__semihost__SemihostExit, %function
bn_pkg__semihost__SemihostExit:
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
	.size   bn_pkg__semihost__SemihostExit, . - bn_pkg__semihost__SemihostExit
