// rt_stubs.c — pkg/rt's residual C-implemented entry points.
//
// pkg/rt's libc-dependent operations live in pkg/libc (see
// runtime/libc_stubs.c). What's left here is the small set of
// C-implemented helpers that aren't libc but are needed by the
// libc-target pkg/rt impl.

#include <stdint.h>

// CallDtor: invoke a function pointer of type void (*)(void *).
// Declared in pkg/rt.bni as func CallDtor(dtor *uint8, ptr *uint8).
// Needed only because Binate doesn't yet have callable function-
// pointer types — once it does, this can be retired.
void bn_rt__CallDtor(void *dtor, void *ptr) {
    typedef void (*dtor_fn)(void *);
    ((dtor_fn)dtor)(ptr);
}
