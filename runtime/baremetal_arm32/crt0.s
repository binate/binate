// ARM32 bare-metal crt0 for the v1 arm32-baremetal target.
// Reset vector -> stack setup -> jump into Binate.
//
// Written in the subset of ARM assembly that Binate's own assembler
// (bnas, pkg/binate/asm) accepts: `//` line comments, `.section text`,
// `.global`, `.type`, dot-less local labels, and UAL mnemonics.  bnc assembles
// this file with `bnas -arch arm32` at link time for arm32-baremetal
// (both the LLVM and native backends); it is not fed to clang.
//
// Tuned for QEMU's `virt` machine running ARMv7-A in ARM mode:
//   - RAM starts at 0x40000000.
//   - The linker script (baremetal.ld, or baremetal_test.ld for a test binary)
//     links this at the RAM base and
//     drives the entry point via ENTRY(_start) -> e_entry, so QEMU's
//     `-kernel` loader jumps to _start wherever it lands in .text.
//   - Stack is a full-descending stack from the top of RAM.
//   - CPU exceptions vector to bn_vectors (below), which reports the
//     exception and exits rather than letting it loop in the empty flash
//     at address 0.
//
// `bn_entry` is the synthetic Binate function bnc emits for every
// executable (`<main>.__entry`).  It runs per-package var initializers
// and then calls user `main`.

	.arch arm32

	.section text

	.global _start
	.type _start, %function
	// External references (bnas requires referenced symbols to exist in
	// the symbol table; declaring them global creates the undefined entry
	// that becomes an R_ARM_{CALL,JUMP24} relocation for the linker).
	.global bn_entry
	.global bn_F2_3_pkg8_semihost1_12_SemihostExit
	.global bn_F2_3_pkg8_semihost1_17_SemihostWriteChar
_start:
	// Take exceptions at bn_vectors (below).
	ldr     r0, =bn_vectors
	mcr     p15, 0, r0, c12, c0, 0  // VBAR
	isb                             // an exception from here on uses it
	// Set up the stack pointer at the top of RAM: `_stack_top`, which the
	// linker script defines one past the top (as a full-descending stack
	// wants).  The literal pool holding its address follows the code.
	ldr     sp, =_stack_top

	// Hand control to Binate.  bn_entry runs init dispatchers and then
	// calls main; returns when main returns.
	bl      bn_entry

	// If main returns, exit cleanly via semihosting.  Pass r0 through as
	// the exit code (bn_entry returns void in current shape, so this is 0
	// in practice; a future `func main() int` would route a status here).
	mov     r0, #0
	bl      bn_F2_3_pkg8_semihost1_12_SemihostExit

	// Defensive halt in case SemihostExit ever returns.
crt0_halt:
	b       crt0_halt

// ============================================================
// Exception vectors.  _start points VBAR at bn_vectors (SCTLR.V is clear out
// of reset, so the CPU takes exceptions there rather than at address 0, which
// on QEMU `virt` is empty flash).  Each handler reports the exception through
// semihosting and exits with status 1, as pkg/builtins/rt's fatal errors do,
// so a CPU fault ends the run at once instead of looping in the flash.
//
// Reset never comes through the table and vector 0x14 is not used; a supervisor
// call other than semihosting (which QEMU takes itself), an IRQ and an FIQ are
// not expected either (nothing enables interrupts), so each of those reports
// as an unexpected one.
// ============================================================
	.balign 32                  // VBAR holds a 32-byte-aligned address
bn_vectors:
	b       vec_unexpected      // 0x00 reset
	b       vec_undef           // 0x04 undefined instruction
	b       vec_svc             // 0x08 supervisor call
	b       vec_pabort          // 0x0c prefetch abort
	b       vec_dabort          // 0x10 data abort
	b       vec_unexpected      // 0x14 (not used)
	b       vec_irq             // 0x18 IRQ
	b       vec_fiq             // 0x1c FIQ

// Each handler gathers its report for vec_report: r4 the message, r5 the
// address of the instruction the exception came from (LR less the offset its
// exception adds in ARM state -- everything this target runs is ARM code; a
// Thumb undefined instruction or SVC would report 2 bytes high), r6 the
// faulting address an abort records (DFAR / IFAR), r7 nonzero when r6 holds
// one.
vec_undef:
	ldr     r4, =msg_undef
	sub     r5, lr, #4
	mov     r7, #0
	b       vec_report
vec_pabort:
	ldr     r4, =msg_pabort
	sub     r5, lr, #4
	mrc     p15, 0, r6, c6, c0, 2   // IFAR
	mov     r7, #1
	b       vec_report
vec_dabort:
	ldr     r4, =msg_dabort
	sub     r5, lr, #8
	mrc     p15, 0, r6, c6, c0, 0   // DFAR
	mov     r7, #1
	b       vec_report
vec_svc:
	ldr     r4, =msg_svc
	sub     r5, lr, #4
	mov     r7, #0
	b       vec_report
vec_irq:
	ldr     r4, =msg_irq
	sub     r5, lr, #4
	mov     r7, #0
	b       vec_report
vec_fiq:
	ldr     r4, =msg_fiq
	sub     r5, lr, #4
	mov     r7, #0
	b       vec_report
vec_unexpected:
	ldr     r4, =msg_unexpected
	sub     r5, lr, #4
	mov     r7, #0
	b       vec_report

// vec_report writes "fatal: <message> at pc 0x<r5>[, address 0x<r6>]" and
// exits.  It runs in supervisor mode on a stack of its own, since the exception
// may have come from a stack that ran past its end.  (A stack that runs on into
// the image overwrites these handlers too; nothing here can report that.)  r4-r7 are not banked between
// these modes, so they carry the report across the switch.
vec_report:
	cps     #0x13
	ldr     sp, =vec_stack_top
	ldr     r0, =msg_fatal
	bl      vec_puts
	mov     r0, r4
	bl      vec_puts
	ldr     r0, =msg_at_pc
	bl      vec_puts
	mov     r0, r5
	bl      vec_puthex
	cmp     r7, #0
	beq     vec_report_end
	ldr     r0, =msg_address
	bl      vec_puts
	mov     r0, r6
	bl      vec_puthex
vec_report_end:
	mov     r0, #10             // '\n'
	bl      bn_F2_3_pkg8_semihost1_17_SemihostWriteChar
	mov     r0, #1
	bl      bn_F2_3_pkg8_semihost1_12_SemihostExit
vec_halt:
	b       vec_halt

// vec_puts writes the NUL-terminated string at r0.
vec_puts:
	push    {r8, lr}
	mov     r8, r0
vec_puts_loop:
	ldrb    r0, [r8], #1
	cmp     r0, #0
	beq     vec_puts_done
	bl      bn_F2_3_pkg8_semihost1_17_SemihostWriteChar
	b       vec_puts_loop
vec_puts_done:
	pop     {r8, pc}

// vec_puthex writes r0 as eight hex digits.
vec_puthex:
	push    {r8, r9, r10, lr}
	mov     r8, r0
	mov     r9, #28             // the shift of the top digit
vec_puthex_loop:
	lsr     r0, r8, r9
	and     r0, r0, #15
	cmp     r0, #10
	addlt   r0, r0, #48         // '0'-'9'
	addge   r0, r0, #87         // 'a'-'f'
	bl      bn_F2_3_pkg8_semihost1_17_SemihostWriteChar
	subs    r9, r9, #4
	bge     vec_puthex_loop
	pop     {r8, r9, r10, pc}

	.section rodata
msg_fatal:
	.asciz  "fatal: "
msg_undef:
	.asciz  "undefined instruction"
msg_pabort:
	.asciz  "prefetch abort"
msg_dabort:
	.asciz  "data abort"
msg_svc:
	.asciz  "unexpected supervisor call"
msg_irq:
	.asciz  "unexpected IRQ"
msg_fiq:
	.asciz  "unexpected FIQ"
msg_unexpected:
	.asciz  "unexpected exception"
msg_at_pc:
	.asciz  " at pc 0x"
msg_address:
	.asciz  ", address 0x"

	.section bss
	.balign 8
vec_stack:
	.zero   1024
vec_stack_top:
