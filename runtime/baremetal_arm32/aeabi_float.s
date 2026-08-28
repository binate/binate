// ARM32 bare-metal AEABI soft-float shims for the v1 arm32-baremetal target —
// the C-free replacement for libgcc.a's soft-float members.
//
// The native arm32 backend lowers float ops to calls to the ARM run-time ABI
// (AEABI, IHI0043) soft-float helpers.  The IEEE-754 work is implemented in
// Binate in pkg/builtins/softfloat (pure integer bit-manipulation), force-loaded
// on this target; these thin shims map each `__aeabi_*` entry to the matching
// softfloat function.  The AEABI soft-float ABI and Binate's arm32 ABI agree on
// register placement (a double / uint64 in r0:r1, an int in r0), so each shim is
// a bare tail-call `b` — no marshaling.
//
// NOTE: libgcc bundles float helpers into per-member objects (e.g.
// _arm_addsubdf3.o = dadd/dsub/f2d/i2d/...), so a shim may only cover a symbol
// whose entire libgcc member is shimmed here — otherwise the member is pulled
// (for an un-shimmed sibling) and re-defines the shimmed symbol (duplicate).
// Single-symbol members (d2iz, d2f, f2iz, ...) can be shimmed individually.
//
// Referenced softfloat symbols are declared .global so bnas emits the undefined
// entry the linker resolves against the force-loaded softfloat object.

	.arch arm32

	.section text

// __aeabi_d2iz(double a) -> int : binary64 -> int32, round toward zero.
//   a in r0:r1 ; result in r0.  softfloat.F64ToI32(uint64) int matches.
//   (_arm_fixdfsi.o is a single-symbol libgcc member.)
	.global __aeabi_d2iz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToI32
__aeabi_d2iz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToI32

// __aeabi_d2f(double a) -> float : binary64 -> binary32 (round to nearest even).
//   a in r0:r1 ; result in r0.  softfloat.F64ToF32(uint64) uint32 matches.
//   (_arm_truncdfsf2.o is a single-symbol libgcc member.)
	.global __aeabi_d2f
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToF32
__aeabi_d2f:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToF32

// ============================================================
// Double add/sub group — libgcc member _arm_addsubdf3.o (dadd, dsub, drsub,
// f2d, i2d, l2d, ui2d, ul2d).  ALL of its symbols the suite pulls are shimmed
// here so the member is never linked from libgcc.  Doubles pass in r0:r1 / r2:r3
// and return in r0:r1; single-word args (f2d/i2d/ui2d) in r0 — all match the
// corresponding softfloat function signatures, so each is a bare tail-call.
// ============================================================
	.global __aeabi_dadd
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F64Add
__aeabi_dadd:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F64Add

	.global __aeabi_dsub
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F64Sub
__aeabi_dsub:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F64Sub

	.global __aeabi_drsub
	.global bn_F3_3_pkg8_builtins9_softfloat1_7_F64Rsub
__aeabi_drsub:
	b       bn_F3_3_pkg8_builtins9_softfloat1_7_F64Rsub

	.global __aeabi_f2d
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToF64
__aeabi_f2d:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToF64

	.global __aeabi_i2d
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_I32ToF64
__aeabi_i2d:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_I32ToF64

	.global __aeabi_l2d
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_I64ToF64
__aeabi_l2d:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_I64ToF64

	.global __aeabi_ui2d
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_U32ToF64
__aeabi_ui2d:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_U32ToF64

	.global __aeabi_ul2d
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_U64ToF64
__aeabi_ul2d:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_U64ToF64

// ============================================================
// Float add/sub group — libgcc member _arm_addsubsf3.o (fadd, fsub, frsub,
// i2f, l2f, ui2f, ul2f).  ALL of its symbols the suite pulls are shimmed here
// so the member is never linked from libgcc.  A binary32 / int / uint passes in
// r0 and returns in r0; a 64-bit int (l2f/ul2f) in r0:r1 — all match the
// corresponding softfloat function signatures, so each is a bare tail-call.
// ============================================================
	.global __aeabi_fadd
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F32Add
__aeabi_fadd:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F32Add

	.global __aeabi_fsub
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F32Sub
__aeabi_fsub:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F32Sub

	.global __aeabi_frsub
	.global bn_F3_3_pkg8_builtins9_softfloat1_7_F32Rsub
__aeabi_frsub:
	b       bn_F3_3_pkg8_builtins9_softfloat1_7_F32Rsub

	.global __aeabi_i2f
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_I32ToF32
__aeabi_i2f:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_I32ToF32

	.global __aeabi_l2f
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_I64ToF32
__aeabi_l2f:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_I64ToF32

	.global __aeabi_ui2f
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_U32ToF32
__aeabi_ui2f:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_U32ToF32

	.global __aeabi_ul2f
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_U64ToF32
__aeabi_ul2f:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_U64ToF32

// ============================================================
// Float mul/div group — libgcc member _arm_muldivsf3.o (fmul, fdiv).  Both
// symbols the suite pulls are shimmed here so the member is never linked from
// libgcc.  Two binary32 args in r0/r1, result in r0 — matches F32Mul/F32Div,
// so each shim is a bare tail-call.
// ============================================================
	.global __aeabi_fmul
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F32Mul
__aeabi_fmul:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F32Mul

	.global __aeabi_fdiv
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F32Div
__aeabi_fdiv:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F32Div

// ============================================================
// Double mul/div group — libgcc member _arm_muldivdf3.o (dmul, ddiv).  Both
// symbols the suite pulls are shimmed here so the member is never linked from
// libgcc.  Two doubles in r0:r1 / r2:r3, result in r0:r1 — matches
// F64Mul/F64Div, so each shim is a bare tail-call.
// ============================================================
	.global __aeabi_dmul
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F64Mul
__aeabi_dmul:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F64Mul

	.global __aeabi_ddiv
	.global bn_F3_3_pkg8_builtins9_softfloat1_6_F64Div
__aeabi_ddiv:
	b       bn_F3_3_pkg8_builtins9_softfloat1_6_F64Div

// ============================================================
// Compare groups — libgcc members _arm_cmpdf2.o (dcmpeq/dcmplt/dcmple/dcmpgt/
// dcmpge) + _arm_unorddf2.o (dcmpun), and the sf equivalents.  The backend
// emits these 0/1-returning AEABI compares; shimming them keeps the members
// from being pulled.  (The flag-setting __aeabi_cdcmp* variants that also live
// in _arm_cmpdf2.o are not emitted by the backend and are not provided here —
// compiler-rt, our reference, does not define them either.)  Each helper takes
// the same operand registers as the arithmetic ones (a double in r0:r1, a
// float in r0) and returns 0/1 in r0, matching the F{64,32}Cmp* signatures, so
// each shim is a bare tail-call.
// ============================================================
	.global __aeabi_dcmpeq
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpEq
__aeabi_dcmpeq:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpEq

	.global __aeabi_dcmplt
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpLt
__aeabi_dcmplt:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpLt

	.global __aeabi_dcmple
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpLe
__aeabi_dcmple:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpLe

	.global __aeabi_dcmpgt
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpGt
__aeabi_dcmpgt:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpGt

	.global __aeabi_dcmpge
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpGe
__aeabi_dcmpge:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpGe

	.global __aeabi_dcmpun
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpUn
__aeabi_dcmpun:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64CmpUn

	.global __aeabi_fcmpeq
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpEq
__aeabi_fcmpeq:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpEq

	.global __aeabi_fcmplt
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpLt
__aeabi_fcmplt:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpLt

	.global __aeabi_fcmple
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpLe
__aeabi_fcmple:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpLe

	.global __aeabi_fcmpgt
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpGt
__aeabi_fcmpgt:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpGt

	.global __aeabi_fcmpge
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpGe
__aeabi_fcmpge:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpGe

	.global __aeabi_fcmpun
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpUn
__aeabi_fcmpun:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32CmpUn

// ============================================================
// Float -> int conversion group — single-symbol libgcc members _arm_fixsfsi.o
// (f2iz), _arm_fixunssfsi.o (f2uiz), _fixsfdi.o (f2lz), _fixunssfdi.o (f2ulz),
// _arm_fixunsdfsi.o (d2uiz), _fixdfdi.o (d2lz), _fixunsdfdi.o (d2ulz).  (d2iz's
// _arm_fixdfsi.o is already shimmed above.)  A double arg is in r0:r1, a float
// in r0; a 32-bit result in r0, a 64-bit result in r0:r1 — all match the
// F{64,32}To{I,U}{32,64} signatures, so each shim is a bare tail-call.  The
// compiler guards saturation/Inf/NaN before the call (emitGuardedFloatToInt).
// ============================================================
	.global __aeabi_d2uiz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToU32
__aeabi_d2uiz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToU32

	.global __aeabi_d2lz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToI64
__aeabi_d2lz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToI64

	.global __aeabi_d2ulz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToU64
__aeabi_d2ulz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F64ToU64

	.global __aeabi_f2iz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToI32
__aeabi_f2iz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToI32

	.global __aeabi_f2uiz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToU32
__aeabi_f2uiz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToU32

	.global __aeabi_f2lz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToI64
__aeabi_f2lz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToI64

	.global __aeabi_f2ulz
	.global bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToU64
__aeabi_f2ulz:
	b       bn_F3_3_pkg8_builtins9_softfloat1_8_F32ToU64
