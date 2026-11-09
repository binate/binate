// ARM32 bare-metal stack guard for the arm32-baremetal target: an unmapped region at
// the bottom of the stack, so that a stack running past its end takes a data abort
// (which crt0.s's vectors report as a stack overflow) instead of overwriting the heap.
//
// Written in the subset of ARM assembly that Binate's own assembler (bnas) accepts and
// assembled by bnc at link time.  bnc links this file by default and a no-op
// (stack_guard_off.s) in its place under -fno-baremetal-stack-guard; either one
// defines bn_stack_guard_init, which crt0.s calls once the stack pointer is set.
//
// The guard needs an MMU, which not every ARMv7 core has, so bn_stack_guard_init first
// reads ID_MMFR0 and returns at once on a core without the VMSA.  On one with it, it
// builds a short-descriptor translation table that maps all 4 GiB to themselves with
// the attributes every data access has with the MMU off (strongly-ordered, full
// access, executable) -- so the program sees the same memory -- except for GUARD_BYTES
// at the bottom of the stack, from __heap_end rounded up to GUARD_BYTES: those 4 KiB
// pages are left unmapped, in a second-level table for the 1 MiB they lie in.  It
// records the guard's bounds in bn_stack_guard_bounds (crt0.s) and turns the MMU on.
// A layout whose stack is no larger than the guard gets no guard.
//
// One descriptor gives both data accesses and instruction fetches their memory type,
// and with the MMU off instruction fetches are Normal memory (cached, where boot code
// turned the I-cache on), so under this table they are strongly-ordered too: on such
// a core the guard costs the instruction cache.

	.arch arm32

	.section text

	.global bn_stack_guard_init
	.type bn_stack_guard_init, %function
	.global bn_stack_guard_bounds
	.global __heap_end
	.global _stack_top

// GUARD_BYTES (64 KiB) is the guard's size: a multiple of the 4 KiB page, and a
// power of two no larger than 1 MiB, so the aligned guard lies in a single 1 MiB
// section.  A frame larger than it could step over it.
bn_stack_guard_init:
	push    {r4, r5, r6, r7, r8, lr}
	mrc     p15, 0, r0, c0, c1, 4   // ID_MMFR0
	and     r0, r0, #15             // VMSA support: 3 or more is a VMSAv7 MMU
	cmp     r0, #3
	blo     sg_done

	// The guard: [lo, hi), lo = __heap_end rounded up to 64 KiB.
	ldr     r4, =__heap_end
	ldr     r0, =0xffff
	add     r4, r4, r0
	bic     r4, r4, r0              // r4 = lo
	add     r5, r4, #0x10000        // r5 = hi
	ldr     r0, =_stack_top
	cmp     r5, r0
	bhs     sg_done                 // no stack above the guard: leave it off

	// First level: 4096 sections, each mapped to itself, strongly-ordered
	// (TEX 000, C 0, B 0), full access (AP 011), domain 0.
	ldr     r6, =sg_l1
	ldr     r1, =0xc02
	mov     r2, #0
sg_l1_loop:
	orr     r3, r1, r2, lsl #20
	str     r3, [r6, r2, lsl #2]
	add     r2, r2, #1
	cmp     r2, #4096
	blo     sg_l1_loop

	// Second level for the guard's 1 MiB: 256 small pages mapped to themselves
	// (strongly-ordered, AP 011), except the guard's, left as faults (0).
	ldr     r7, =sg_l2
	lsr     r8, r4, #20
	lsl     r8, r8, #20             // r8 = the 1 MiB the guard lies in
	mov     r2, #0
sg_l2_loop:
	add     r3, r8, r2, lsl #12     // the page's address
	cmp     r3, r4
	blo     sg_l2_map
	cmp     r3, r5
	blo     sg_l2_fault
sg_l2_map:
	orr     r3, r3, #0x32           // small page, AP 011
	b       sg_l2_store
sg_l2_fault:
	mov     r3, #0
sg_l2_store:
	str     r3, [r7, r2, lsl #2]
	add     r2, r2, #1
	cmp     r2, #256
	blo     sg_l2_loop
	lsr     r0, r4, #20
	orr     r3, r7, #1              // a page-table descriptor, domain 0
	str     r3, [r6, r0, lsl #2]

	// Record the bounds for crt0.s's data-abort handler.
	ldr     r0, =bn_stack_guard_bounds
	str     r4, [r0]
	str     r5, [r0, #4]

	// Turn the MMU on: short descriptors from TTBR0, domain 0 a client (its
	// descriptors' access permissions apply), the TLBs emptied first.
	dsb
	mov     r0, #0
	mcr     p15, 0, r0, c2, c0, 2   // TTBCR: TTBR0 for all addresses, short descriptors
	mcr     p15, 0, r6, c2, c0, 0   // TTBR0: the first-level table, walks uncached
	mov     r0, #1
	mcr     p15, 0, r0, c3, c0, 0   // DACR: domain 0 client
	mov     r0, #0
	mcr     p15, 0, r0, c8, c7, 0   // TLBIALL
	dsb
	isb
	mrc     p15, 0, r0, c1, c0, 0   // SCTLR
	// Clear what would reread the table's descriptors -- WXN and UWXN (every page
	// here is writable, so they would make all of it execute-never), TRE (TEX
	// remap) and AFE (AP[0] as an access flag) -- whatever reset or a loader left.
	bic     r0, r0, #0x180000       // WXN, UWXN
	bic     r0, r0, #0x30000000     // TRE, AFE
	orr     r0, r0, #1              // M
	mcr     p15, 0, r0, c1, c0, 0
	isb
sg_done:
	pop     {r4, r5, r6, r7, r8, pc}

	.section bss
// The first-level table is 16 KiB, 16 KiB-aligned (TTBR0 holds its address); the
// second-level one 1 KiB, 1 KiB-aligned.
	.balign 16384
sg_l1:
	.zero   16384
sg_l2:
	.zero   1024
