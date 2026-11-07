/* Output sections shared by the arm32-baremetal linker scripts — baremetal.ld (a
 * program) and baremetal_test.ld (a `bnc --test` binary) — for QEMU's `virt` ARMv7-A
 * machine.  Each of those defines the RAM region, INCLUDEs this file, and then lays
 * out the heap and the stack above what it places.  No MMU / paging; identity-mapped
 * flat.
 *
 * Sections we explicitly route:
 *   .text.startup — reserved for a startup section placed first; the
 *                   crt0 lands in plain .text and the entry point is
 *                   taken from ENTRY(_start) -> e_entry (QEMU's -kernel
 *                   loader honors the ELF entry), so its physical position
 *                   in .text does not matter.  The KEEP stays as a
 *                   forward-looking slot for a real-hardware reset vector.
 *   .text         — crt0 + Binate-compiled code + semihost helpers.
 *   .rodata       — string constants and the per-string
 *                   %BnManagedSlice globals bnc emits.
 *   .data / .bss  — initialized / zero-init globals.
 */

SECTIONS
{
	.text : ALIGN(4) {
		KEEP(*(.text.startup))
		*(.text*)
		*(.rodata*)
	} > RAM

	/* ARM unwind tables.  We don't run the unwinder in v1, but
	 * compiled rt helpers (e.g. rt.BoundsCheck) plus libgcc.a's
	 * __aeabi_* helpers reference `__exidx_start` and `__exidx_end`
	 * even when no actual unwinding happens — so we must keep the
	 * section + define the markers (an empty exidx is fine; libgcc
	 * just walks start..end looking for matching PCs).
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
}
