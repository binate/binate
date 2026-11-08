/* Linker script bnc links an arm32-baremetal `--test` binary with: baremetal.ld's
 * layout over 256 MiB of RAM, where the heap takes everything the image and a 16 MiB
 * stack leave.  A test binary carries a package's whole test suite — its code, its
 * test data, and the allocations a run of the whole suite adds up to — so it gets far
 * more memory than a program.  The unit-test runner launches QEMU with `-m 256M` to
 * match.
 *
 *   heap   — from `__heap_start` (8-aligned, just past .bss) to `__heap_end`, 16 MiB
 *            below the top of RAM.
 *   stack  — full-descending from `_stack_top` (the top of RAM) down to the heap.
 */

ENTRY(_start)

MEMORY
{
	RAM (rwx) : ORIGIN = 0x40000000, LENGTH = 256M
}

SECTIONS
{
	__heap_start = ALIGN(__bss_end, 8);
	_stack_top = ORIGIN(RAM) + LENGTH(RAM);
	__heap_end = _stack_top - 16M;
}

ASSERT(__heap_start < __heap_end, "baremetal_test.ld: the image does not fit below the stack")
