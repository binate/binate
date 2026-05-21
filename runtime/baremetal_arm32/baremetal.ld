/* Linker script for the v1 arm32-baremetal target — QEMU's `virt`
 * ARMv7-A machine.
 *
 * Memory map: a single 1 MiB region starting at 0x40000000 (the
 * default `virt` RAM base).  Code and rodata go at the bottom of
 * the region, then data + bss, then stack growing down from the
 * top.  No MMU / paging in v1; identity-mapped flat.
 *
 * Sections we explicitly route:
 *   .text.startup — the crt0's _start label.  Placed first so
 *                   the entry point sits at 0x40000000.
 *   .text         — Binate-compiled code + semihost.s helpers.
 *   .rodata       — string constants and the per-string
 *                   %BnManagedSlice globals bnc emits.
 *   .data / .bss  — initialized / zero-init globals.
 *
 * `_stack_top` is the symbol crt0.s loads into sp at boot.
 */

ENTRY(_start)

MEMORY
{
	RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 1M
}

SECTIONS
{
	.text : ALIGN(4) {
		KEEP(*(.text.startup))
		*(.text*)
		*(.rodata*)
	} > RAM

	/* ARM unwind tables.  We don't run the unwinder in v1, but
	 * libgcc.a's bn_rt__BoundsCheck / __aeabi_* helpers reference
	 * `__exidx_start` and `__exidx_end` even when no actual
	 * unwinding happens — so we must keep the section + define
	 * the markers (an empty exidx is fine; libgcc just walks
	 * start..end looking for matching PCs).
	 */
	.ARM.exidx : ALIGN(4) {
		__exidx_start = .;
		*(.ARM.exidx*)
		__exidx_end = .;
	} > RAM

	.ARM.extab : ALIGN(4) {
		*(.ARM.extab*)
	} > RAM

	.data : ALIGN(4) {
		*(.data*)
	} > RAM

	.bss : ALIGN(4) {
		__bss_start = .;
		*(.bss*)
		*(COMMON)
		__bss_end = .;
	} > RAM

	. = ALIGN(8);
	_stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
