// rt_stubs.c — pkg/rt's residual C-implemented entry points.
//
// pkg/rt's libc-dependent operations live in pkg/libc (see
// runtime/libc_stubs.c). What's left here is the small set of
// C-implemented helpers that aren't libc but are needed by the
// libc-target pkg/rt impl: function-pointer dispatch (until
// Binate gets callable function-pointer types) and a memcpy
// trampoline still emitted directly by pkg/codegen / pkg/native.

#include <string.h>
#include <stdint.h>

// CallDtor: invoke a function pointer of type void (*)(void *).
// Declared in pkg/rt.bni as func CallDtor(dtor *uint8, ptr *uint8).
void bn_rt__CallDtor(void *dtor, void *ptr) {
    typedef void (*dtor_fn)(void *);
    ((dtor_fn)dtor)(ptr);
}

// Legacy memcpy entry point still emitted by pkg/codegen and
// pkg/native/arm64 directly into LLVM IR / asm. To be retired in
// a follow-up commit that switches those backends to emit
// @bn_libc__Memcpy instead.
void bn_rt__c_memcpy(void *dst, const void *src, int64_t size) {
    memcpy(dst, src, (size_t)size);
}
