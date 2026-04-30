// Stub definitions of pkg/rt symbols that runtime/binate_runtime.c
// references at link time.
//
// This file exists so pkg/native/* unit tests that link a minimal
// .o + binate_runtime.c (without pkg/rt's compiled body) can resolve
// the symbols. The stubs are weak so the conformance suite — which
// always links pkg/rt — uses the real symbols and ignores these.

#include <stdlib.h>

// pkg/rt.RawFree forward-declared in binate_runtime.c. The C-side
// managed_alloc helper stores its address into header[1] so a later
// rt.Free dispatches indirect through it. The libc-target rt's real
// RawFree is a calloc/free wrapper, so the stub just calls free —
// behaves identically when reached.
__attribute__((weak)) void bn_rt__RawFree(void *ptr) {
    free(ptr);
}
