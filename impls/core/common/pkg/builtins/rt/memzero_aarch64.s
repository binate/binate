// #[build(is(arch, "aarch64"))]
// AArch64 rt.MemZero: zero `size` (x1) bytes at `ptr` (x0), returning void
// (AAPCS64).  A hand-written fill that matches what LLVM lowers a zero-fill loop
// to.  Two regimes:
//   - Large fills (size >= 256) on a standard 64-byte DC-ZVA-block CPU use
//     `DC ZVA` for the block-aligned middle — one instruction zeroes a whole
//     cache line with no read-for-ownership, the fastest AArch64 zero-fill.  The
//     unaligned head and the sub-block tail use STP.
//   - Small/medium fills, or any CPU where DC ZVA is prohibited or the block is
//     not 64 bytes, use a 64-byte-unrolled STP-of-XZR bulk, a 16-byte STP loop,
//     then a byte tail (16-64 bytes per store) — avoiding the DCZID read and
//     block-alignment overhead where they would not pay off.
// The portable word-at-a-time Binate MemZero (rt_memzero.bn, the native backend
// emits it as a scalar word loop) is #[build(!is(arch, "aarch64"))]-gated off,
// and this defines the same rt.MemZero symbol instead.
//
// A leaf using only x0-x5 — no stack frame, no callee-saved registers.  size<=0
// is a no-op (the portable body aborts on size<0; that path is never hit — Alloc
// only passes a non-negative payload size).  DC ZVA never overruns: x0 is first
// brought to 64-byte alignment, and a block is zeroed only while >= 64 bytes
// remain, so every zeroed block lies within [ptr, ptr+size).  Local labels are
// `L`-prefixed so their branches resolve in-section (Mach-O treats a non-`L`
// defined symbol as an atom boundary).  `.global_c` gives the symbol the
// platform C-prefix (`_` on Mach-O, none on ELF).
.arch aarch64
.section text
.global_c bn_F3_3_pkg8_builtins2_rt1_7_MemZero
bn_F3_3_pkg8_builtins2_rt1_7_MemZero:
 cmp x1, #0
 b.le Lmz_done
 // Only bother with DC ZVA for large fills — below this the head/tail and the
 // DCZID read outweigh the per-line saving.
 cmp x1, #256
 b.lt Lmz_64
 // DC ZVA usable only when the block is the standard 64 bytes and not
 // prohibited: DCZID_EL0 low 5 bits == 4  (DZP[bit4]=0, BS[bits3:0]=4).
 mrs x2, dczid_el0
 and x2, x2, #0x1f
 cmp x2, #4
 b.ne Lmz_64
 // Head: byte lead-in to 16-alignment, then STP-16 up to 64-alignment.
Lmz_a16:
 tst x0, #15
 b.eq Lmz_a64
 strb wzr, [x0], #1
 sub x1, x1, #1
 b Lmz_a16
Lmz_a64:
 tst x0, #63
 b.eq Lmz_zva
 stp xzr, xzr, [x0], #16
 sub x1, x1, #16
 b Lmz_a64
 // Bulk: one DC ZVA per 64-byte cache line while a whole block remains.
Lmz_zva:
 cmp x1, #64
 b.lt Lmz_16
 dc zva, x0
 add x0, x0, #64
 sub x1, x1, #64
 b Lmz_zva
 // 64-byte-unrolled STP bulk (also the small-fill / DC-ZVA-unavailable path).
Lmz_64:
 cmp x1, #64
 b.lt Lmz_16
 stp xzr, xzr, [x0], #16
 stp xzr, xzr, [x0], #16
 stp xzr, xzr, [x0], #16
 stp xzr, xzr, [x0], #16
 sub x1, x1, #64
 b Lmz_64
Lmz_16:
 cmp x1, #16
 b.lt Lmz_tail
 stp xzr, xzr, [x0], #16
 sub x1, x1, #16
 b Lmz_16
Lmz_tail:
 cbz x1, Lmz_done
Lmz_byte:
 strb wzr, [x0], #1
 sub x1, x1, #1
 cbnz x1, Lmz_byte
Lmz_done:
 ret
