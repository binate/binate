/* Output sections shared by the arm32-baremetal linker scripts — baremetal.ld (a
 * program) and baremetal_test.ld (a `bnc --test` binary) — for QEMU's `virt` ARMv7-A
 * machine.  bnc links this script with one of those, which defines the RAM region
 * these sections go into and lays out the heap and the stack past `__bss_end`.  The
 * two name each other's region and symbols only, which lld (bnc's bare-metal linker)
 * resolves once it has read both, so their order does not matter.  Addresses are
 * physical: where the core has an MMU, stack_guard.s maps every address to itself.
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
 *
 * Every other input section is named too, the non-allocated ones at the end,
 * because bnc links with --orphan-handling=error: lld places a section no script
 * names (an orphan) after the last section like it, so an allocated orphan — a C
 * object's .noinit, say — would land past .bss, on the heap.
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

	/* The non-allocated sections: build attributes, compiler comments, the symbol
	 * tables and DWARF.  They are named only so that no input section is an orphan
	 * (see above).
	 */
	.ARM.attributes 0 : { KEEP(*(.ARM.attributes)) KEEP(*(.gnu.attributes)) }
	.comment 0 : { *(.comment) }
	.symtab 0 : { *(.symtab) }
	.strtab 0 : { *(.strtab) }
	.shstrtab 0 : { *(.shstrtab) }
	.debug_aranges 0 : { *(.debug_aranges) }
	.debug_pubnames 0 : { *(.debug_pubnames) }
	.debug_pubtypes 0 : { *(.debug_pubtypes) }
	.debug_gnu_pubnames 0 : { *(.debug_gnu_pubnames) }
	.debug_gnu_pubtypes 0 : { *(.debug_gnu_pubtypes) }
	.debug_info 0 : { *(.debug_info) }
	.debug_abbrev 0 : { *(.debug_abbrev) }
	.debug_line 0 : { *(.debug_line) }
	.debug_frame 0 : { *(.debug_frame) }
	.debug_str 0 : { *(.debug_str) }
	.debug_loc 0 : { *(.debug_loc) }
	.debug_macinfo 0 : { *(.debug_macinfo) }
	.debug_ranges 0 : { *(.debug_ranges) }
	.debug_types 0 : { *(.debug_types) }
	.debug_addr 0 : { *(.debug_addr) }
	.debug_line_str 0 : { *(.debug_line_str) }
	.debug_loclists 0 : { *(.debug_loclists) }
	.debug_macro 0 : { *(.debug_macro) }
	.debug_names 0 : { *(.debug_names) }
	.debug_rnglists 0 : { *(.debug_rnglists) }
	.debug_str_offsets 0 : { *(.debug_str_offsets) }
	.debug_sup 0 : { *(.debug_sup) }
}
