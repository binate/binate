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
 *            into sp) down to the heap.
 *
 * bnc links a `--test` binary with baremetal_test.ld instead, which gives a whole
 * test suite more RAM.  bnc puts this directory on the link's search path (-L), where
 * the INCLUDE below finds the shared sections.
 */

ENTRY(_start)

MEMORY
{
	RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 16M
}

INCLUDE baremetal_sections.ld

SECTIONS
{
	. = ALIGN(8);
	__heap_start = .;
	__heap_end = __heap_start + 4M;
	_stack_top = ORIGIN(RAM) + LENGTH(RAM);
}

ASSERT(__heap_end <= _stack_top, "baremetal.ld: the image and its 4 MiB heap do not fit in RAM")
