/* Linker script for the arm32-baremetal target — QEMU's `virt` ARMv7-A machine.
 *
 * Memory map: a single 16 MiB region starting at 0x40000000 (the default `virt`
 * RAM base), so a program runs under `-m 16M`.  Code and rodata go at the bottom
 * of the region, then data + bss (baremetal_sections.ld), then the heap, and the
 * stack grows down from the top.
 *
 *   heap   — 4 MiB from `__heap_start` (8-aligned, just past .bss) to `__heap_end`:
 *            the arena pkg/builtins/rt allocates from.  Only symbols, not a section,
 *            so the image does not carry it and the loader does not zero it.
 *   stack  — full-descending from `_stack_top` (the top of RAM, which crt0.s loads
 *            into sp) down to the heap -- or, where the core has an MMU, to the
 *            unmapped guard stack_guard.s leaves above the heap.
 *
 * bnc links this script with the output sections (baremetal_sections.ld), and links
 * a `--test` binary with baremetal_test.ld in its place, which gives a whole test
 * suite more RAM.
 */

ENTRY(_start)

MEMORY
{
	RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 16M
}

SECTIONS
{
	__heap_start = ALIGN(__bss_end, 8);
	__heap_end = __heap_start + 4M;
	_stack_top = ORIGIN(RAM) + LENGTH(RAM);
}

ASSERT(__heap_end <= _stack_top, "baremetal.ld: the image and its 4 MiB heap do not fit in RAM")
