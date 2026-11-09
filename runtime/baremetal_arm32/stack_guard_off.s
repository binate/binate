// The arm32-baremetal stack guard left off: bnc links this file in place of
// stack_guard.s under -fno-baremetal-stack-guard.  bn_stack_guard_init returns at once,
// so the MMU stays off and bn_stack_guard_bounds (crt0.s) stays empty.

	.arch arm32

	.section text

	.global bn_stack_guard_init
	.type bn_stack_guard_init, %function
bn_stack_guard_init:
	bx      lr
