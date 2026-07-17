// Stub definitions of pkg/builtins/rt symbols that runtime/binate_runtime.c
// references at link time.
//
// This file exists so pkg/binate/native/* unit tests that link a minimal
// .o + binate_runtime.c (without pkg/builtins/rt's compiled body) can resolve
// the symbols. The stubs are weak so the conformance suite — which
// always links pkg/builtins/rt — uses the real symbols and ignores these.

#include <stdlib.h>

// pkg/builtins/rt.RawFree forward-declared in binate_runtime.c. The C-side
// managed_alloc helper stores its address into header[1] so a later
// rt.Free dispatches indirect through it. The libc-target rt's real
// RawFree is a calloc/free wrapper, so the stub just calls free —
// behaves identically when reached.
__attribute__((weak)) void bn_F3_3_pkg8_builtins2_rt1_7_RawFree(void *ptr) {
    free(ptr);
}

// pkg/binate/native/* link tests emit a Binate `__entry` (which mangles to
// `bn_entry` for package "main") and link it against binate_runtime.c + this stub,
// expecting the runtime to supply the C `main` that crt0 calls.  The production C
// `main` moved OUT of binate_runtime.c into the Binate startup package
// (startup._entry, #[c_export("main")]) — which these minimal link tests do not
// compile — so supply a test `main` here that hands off to bn_entry, the same shape
// the old C `main` had.  Weak, like the rt stubs: any real `main` a build links (a
// compiled startup._entry) overrides it, so this is inert outside these tests.
extern void bn_entry(void);
__attribute__((weak)) int main(void) {
    bn_entry();
    return 0;
}
