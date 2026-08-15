// ARM32 bare-metal crt0 for the v1 arm32-baremetal target.
// Reset vector -> stack setup -> jump into Binate.
//
// Written in the subset of ARM assembly that Binate's own assembler
// (bnas, pkg/binate/asm) accepts: `//` line comments, `.section text`,
// `.global`, dot-less local labels, and UAL mnemonics.  bnc assembles
// this file with `bnas -arch arm32` at link time for arm32-baremetal
// (both the LLVM and native backends); it is not fed to clang.
//
// Tuned for QEMU's `virt` machine running ARMv7-A in ARM mode:
//   - RAM starts at 0x40000000.
//   - The linker script (baremetal.ld) links this at the RAM base and
//     drives the entry point via ENTRY(_start) -> e_entry, so QEMU's
//     `-kernel` loader jumps to _start wherever it lands in .text.
//   - Stack is a full-descending stack from the top of RAM.
//
// `bn_entry` is the synthetic Binate function bnc emits for every
// executable (`<main>.__entry`).  It runs per-package var initializers
// and then calls user `main`.

	.arch arm32

	.section text

	.global _start
	// External references (bnas requires referenced symbols to exist in
	// the symbol table; declaring them global creates the undefined entry
	// that becomes an R_ARM_{CALL,JUMP24} relocation for the linker).
	.global bn_entry
	.global bn_F2_3_pkg8_semihost1_12_SemihostExit
_start:
	// Set up the stack pointer at the top of RAM.
	//
	// NOTE: this hardcodes _stack_top = ORIGIN(RAM) + LENGTH(RAM) =
	// 0x40000000 + 16 MiB = 0x41000000, which is the value baremetal.ld
	// computes as `_stack_top`.  bnas has no literal-pool / symbol-load
	// pseudo-instruction, so a linker-resolved `ldr sp, =_stack_top`
	// isn't available; the value is duplicated here instead.  If you
	// change RAM ORIGIN or LENGTH in baremetal.ld, update this pair too
	// (a full-descending stack wants sp = one-past-the-top-of-RAM).
	movw    sp, #0x0000     // low16  of 0x41000000
	movt    sp, #0x4100     // high16 of 0x41000000

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
