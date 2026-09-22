// #[build(is(arch, "aarch64"))]
// AArch64 rt.MemZero: zero `size` (x1) bytes at `ptr` (x0), returning void
// (AAPCS64).  A hand-written wide-store fill that matches what LLVM lowers a
// zero-fill loop to: a 64-byte unrolled STP-of-XZR bulk (four 16-byte pair
// stores per iteration), then a 16-byte STP loop, then a byte tail — moving
// 16–64 bytes per store, which the portable word-at-a-time Binate MemZero (the
// native backend emits it as a scalar word loop) cannot reach.  So the Binate
// body is #[build(!is(arch, "aarch64"))]-gated off (rt_memzero.bn) and this
// defines the same rt.MemZero symbol instead.
//
// A leaf using only x0/x1 — no stack frame, no callee-saved registers.
// size <= 0 is a no-op (the portable body aborts on size < 0; that path is never
// hit — Alloc only passes a non-negative payload size).  Local labels are
// `L`-prefixed so their branches resolve in-section (the Mach-O atom rule treats
// a non-`L` defined symbol as an atom boundary).  `.global_c` gives the symbol
// the platform C-prefix (`_` on Mach-O, none on ELF), so this one file resolves
// the reference the compiler emits under both object formats.
.arch aarch64
.section text
.global_c bn_F3_3_pkg8_builtins2_rt1_7_MemZero
bn_F3_3_pkg8_builtins2_rt1_7_MemZero:
 cmp x1, #0
 b.le Lmz_done
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
