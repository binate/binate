// ARM32 bare-metal AEABI 64-bit integer runtime helpers for the v1
// arm32-baremetal target — the C-free replacement for the corresponding
// members of GCC's libgcc.a.
//
// The native arm32 backend (and LLVM's arm32 codegen) lower 64-bit
// multiply / divide / remainder / shift to calls to these ARM run-time ABI
// (AEABI, IHI0043) helpers, because the 32-bit ARM ISA has no single-
// instruction form.  Historically they were pulled from libgcc.a via
// `--link-after-objs`; defining them here (an object linked BEFORE that
// archive) resolves the symbols from this file, so libgcc's members are
// never pulled — letting this land while libgcc still supplies the
// soft-float helpers, which are not yet ported.
//
// Written in the bnas subset (see crt0.s / semihost.s): `.arch arm32`,
// `.section text`, `.global`, dot-less local labels, UAL mnemonics, no
// literal pools.  Assembled by bnc's embedded bnas at link time.
//
// Register conventions (confirmed against the AEABI spec + clang output,
// documented in pkg/binate/native/arm32/arm32_int64_libcall.bn):
//   __aeabi_lmul(a=r0:r1, b=r2:r3)     -> r0:r1               (low 64 of product)
//   __aeabi_ldivmod(n=r0:r1, d=r2:r3)  -> quotient r0:r1, remainder r2:r3
//   __aeabi_uldivmod(n=r0:r1, d=r2:r3) -> quotient r0:r1, remainder r2:r3
//   __aeabi_llsl(v=r0:r1, count=r2)    -> r0:r1               (logical shift left)
//   __aeabi_llsr(v=r0:r1, count=r2)    -> r0:r1               (logical shift right)
//   __aeabi_lasr(v=r0:r1, count=r2)    -> r0:r1               (arithmetic shift right)
// In every pair the LOW word is the even register (r0 / r2).  Shift counts
// arrive pre-masked to [0, 63] (the IR's emitGuardedShift), and div/rem
// arrive pre-guarded against a zero divisor and INT64_MIN / -1 (the IR's
// OP_DIV_CHECK), so these routines assume valid inputs.

	.arch arm32

	.section text

// ============================================================
// __aeabi_lmul — low 64 bits of a 64x64 product.  Sign-agnostic: the low
// half is identical for signed and unsigned.
//   product_lo = alo*blo (full 64)              -> r12:r1new via umull
//   product_hi += alo*bhi + ahi*blo (low words)
// r0:r1 = a (alo:ahi), r2:r3 = b (blo:bhi).
// ============================================================
	.global __aeabi_lmul
__aeabi_lmul:
	mul     r3, r0, r3      // r3 = alo * bhi                 (bhi consumed)
	mla     r3, r1, r2, r3  // r3 = alo*bhi + ahi*blo
	umull   r12, r1, r0, r2 // r1:r12 = alo * blo   (r12 lo, r1 hi; regs distinct)
	add     r1, r1, r3      // hi = hi(alo*blo) + cross terms
	mov     r0, r12         // lo = low(alo*blo)
	bx      lr

// ============================================================
// __aeabi_llsl — 64-bit logical shift left, count in r2 (0..63).
//   count < 32 : hi = (hi<<count) | (lo>>(32-count)); lo = lo<<count
//   count >= 32: hi = lo<<(count-32);                 lo = 0
// count==0 rides the count<32 arm (lo>>32 == 0 for a register shift).
// ============================================================
	.global __aeabi_llsl
__aeabi_llsl:
	subs    r3, r2, #32          // r3 = count-32; N=1 (mi) if count<32
	movpl   r1, r0, lsl r3       // count>=32: hi = lo << (count-32)
	movpl   r0, #0               //            lo = 0
	rsbmi   r3, r2, #32          // count<32:  r3 = 32-count
	movmi   r1, r1, lsl r2       //            hi = hi << count
	orrmi   r1, r1, r0, lsr r3   //            hi |= lo >> (32-count)
	movmi   r0, r0, lsl r2       //            lo = lo << count
	bx      lr

// ============================================================
// __aeabi_llsr — 64-bit logical shift right, count in r2 (0..63).
// ============================================================
	.global __aeabi_llsr
__aeabi_llsr:
	subs    r3, r2, #32          // r3 = count-32; mi if count<32
	movpl   r0, r1, lsr r3       // count>=32: lo = hi >> (count-32)
	movpl   r1, #0               //            hi = 0
	rsbmi   r3, r2, #32          // count<32:  r3 = 32-count
	movmi   r0, r0, lsr r2       //            lo = lo >> count
	orrmi   r0, r0, r1, lsl r3   //            lo |= hi << (32-count)
	movmi   r1, r1, lsr r2       //            hi = hi >> count
	bx      lr

// ============================================================
// __aeabi_lasr — 64-bit arithmetic shift right, count in r2 (0..63).
// ============================================================
	.global __aeabi_lasr
__aeabi_lasr:
	subs    r3, r2, #32          // r3 = count-32; mi if count<32
	movpl   r0, r1, asr r3       // count>=32: lo = hi >>a (count-32)
	movpl   r1, r1, asr #31      //            hi = sign fill
	rsbmi   r3, r2, #32          // count<32:  r3 = 32-count
	movmi   r0, r0, lsr r2       //            lo = lo >> count (logical)
	orrmi   r0, r0, r1, lsl r3   //            lo |= hi << (32-count)
	movmi   r1, r1, asr r2       //            hi = hi >>a count
	bx      lr

// ============================================================
// __aeabi_uldivmod — unsigned 64/64 -> quotient r0:r1, remainder r2:r3.
// Binary long division, MSB-first: shift the {rem:dividend} 128-bit pair
// left one bit per step (bringing the next dividend bit into rem's LSB),
// and whenever rem >= divisor, subtract and shift a 1 into the quotient.
// The subtract's carry (set = rem>=d) is fed straight into the quotient
// shift (adcs q, q, q), so no separate bit-set is needed.
//   n = r0:r1 (lo:hi), d = r2:r3 (lo:hi)
//   working: q = r4:r5, rem = r6:r7, i = r8, trial = r9:r10
// ============================================================
	.global __aeabi_uldivmod
__aeabi_uldivmod:
	push    {r4, r5, r6, r7, r8, r9, r10, lr}
	mov     r4, #0              // q_lo
	mov     r5, #0              // q_hi
	mov     r6, #0              // rem_lo
	mov     r7, #0              // rem_hi
	mov     r8, #64             // bit counter
uldivmod_loop:
	// 128-bit left shift of {rem_hi,rem_lo,n_hi,n_lo} by 1.
	adds    r0, r0, r0          // n_lo <<= 1, C = old bit31
	adcs    r1, r1, r1          // n_hi = (n_hi<<1)|C
	adcs    r6, r6, r6          // rem_lo = (rem_lo<<1)|C
	adc     r7, r7, r7          // rem_hi = (rem_hi<<1)|C
	// trial subtract rem - d; C = 1 (hs) iff rem >= d
	subs    r9, r6, r2
	sbcs    r10, r7, r3
	movhs   r6, r9              // commit rem (movhs leaves flags = the subtract's)
	movhs   r7, r10
	// shift quotient left, LSB = (rem>=d) via the carry
	adcs    r4, r4, r4          // q_lo = (q_lo<<1)|C
	adc     r5, r5, r5          // q_hi = (q_hi<<1)|C
	subs    r8, r8, #1
	bne     uldivmod_loop
	mov     r0, r4              // quotient -> r0:r1
	mov     r1, r5
	mov     r2, r6              // remainder -> r2:r3
	mov     r3, r7
	pop     {r4, r5, r6, r7, r8, r9, r10, pc}

// ============================================================
// __aeabi_ldivmod — signed 64/64 -> quotient r0:r1, remainder r2:r3.
// Wrap the unsigned core: quotient sign = sign(n) XOR sign(d); remainder
// sign = sign(n).  |x| via the two's-complement mask trick
// abs = (x ^ m) - m where m = (x < 0 ? -1 : 0) = (x >>a 31 replicated).
// ============================================================
	.global __aeabi_ldivmod
__aeabi_ldivmod:
	push    {r4, r5, r6, lr}
	mov     r4, r1, asr #31     // r4 = sign_n mask (0 or 0xFFFFFFFF)
	eor     r5, r1, r3
	mov     r5, r5, asr #31     // r5 = sign_q mask
	mov     r6, r3, asr #31     // r6 = sign_d mask
	// |n| = (n ^ sign_n) - sign_n
	eor     r0, r0, r4
	eor     r1, r1, r4
	subs    r0, r0, r4
	sbc     r1, r1, r4
	// |d| = (d ^ sign_d) - sign_d
	eor     r2, r2, r6
	eor     r3, r3, r6
	subs    r2, r2, r6
	sbc     r3, r3, r6
	bl      __aeabi_uldivmod    // |n| / |d| -> q=r0:r1, rem=r2:r3 (preserves r4-r10)
	// negate quotient if sign_q (r5): q = (q ^ r5) - r5
	eor     r0, r0, r5
	eor     r1, r1, r5
	subs    r0, r0, r5
	sbc     r1, r1, r5
	// negate remainder if sign_n (r4): rem = (rem ^ r4) - r4
	eor     r2, r2, r4
	eor     r3, r3, r4
	subs    r2, r2, r4
	sbc     r3, r3, r4
	pop     {r4, r5, r6, pc}

// ============================================================
// __aeabi_uidivmod — unsigned 32/32 -> quotient r0, remainder r1.
// Binary long division, in place: shift the {rem:num} pair left one bit per
// step (bringing num's top bit into rem's LSB); whenever rem >= den, subtract
// and set the just-vacated num LSB as the quotient bit.  After 32 steps num
// holds the quotient and r2 the remainder.  The 32-bit ISA has no divide
// instruction, so this open-codes it (the LLVM arm32 backend lowers `/` to
// these calls; the native backend inlines divide and never calls them, but
// they are provided for the LLVM path and for C interop).  Inputs arrive
// pre-guarded against a zero divisor and INT32_MIN / -1 (the IR's
// OP_DIV_CHECK), so a valid den is assumed.
//   n = r0, d = r1 ; working: rem = r2, i = r3
// ============================================================
	.global __aeabi_uidivmod
__aeabi_uidivmod:
	mov     r2, #0              // rem = 0
	mov     r3, #32             // bit counter
uidivmod_loop:
	adds    r0, r0, r0          // num <<= 1, C = old bit31
	adc     r2, r2, r2          // rem = (rem<<1) | C
	cmp     r2, r1              // rem vs den
	subhs   r2, r2, r1          // rem >= den: rem -= den
	orrhs   r0, r0, #1          //            and set quotient LSB
	subs    r3, r3, #1
	bne     uidivmod_loop
	mov     r1, r2              // remainder -> r1 (quotient already in r0)
	bx      lr

// __aeabi_uidiv — unsigned 32/32 -> quotient r0.  Same as uidivmod but the
// caller ignores the remainder, so tail-call it (clobbering r1 is allowed).
	.global __aeabi_uidiv
__aeabi_uidiv:
	b       __aeabi_uidivmod

// ============================================================
// __aeabi_idivmod — signed 32/32 -> quotient r0, remainder r1.  Wrap the
// unsigned core: quotient sign = sign(n) XOR sign(d); remainder sign = sign(n).
// |x| via the two's-complement mask trick abs = (x ^ m) - m where
// m = (x >>a 31).
// ============================================================
	.global __aeabi_idivmod
__aeabi_idivmod:
	push    {r4, r5, lr}
	mov     r4, r0, asr #31     // r4 = sign_n mask
	eor     r5, r0, r1
	mov     r5, r5, asr #31     // r5 = sign_q mask
	mov     r2, r1, asr #31     // r2 = sign_d mask
	// |n| = (n ^ sign_n) - sign_n
	eor     r0, r0, r4
	sub     r0, r0, r4
	// |d| = (d ^ sign_d) - sign_d
	eor     r1, r1, r2
	sub     r1, r1, r2
	bl      __aeabi_uidivmod    // |n| / |d| -> q=r0, rem=r1 (preserves r4, r5)
	// negate quotient if sign_q: q = (q ^ r5) - r5
	eor     r0, r0, r5
	sub     r0, r0, r5
	// negate remainder if sign_n: rem = (rem ^ r4) - r4
	eor     r1, r1, r4
	sub     r1, r1, r4
	pop     {r4, r5, pc}

// __aeabi_idiv — signed 32/32 -> quotient r0.  Tail-call idivmod (the caller
// ignores the remainder left in r1).
	.global __aeabi_idiv
__aeabi_idiv:
	b       __aeabi_idivmod
