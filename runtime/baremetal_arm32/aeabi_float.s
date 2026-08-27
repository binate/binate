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
