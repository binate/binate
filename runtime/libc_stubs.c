// libc_stubs.c — Implements the bn_pkg__libc__* symbols declared by
// pkg/libc.bni: thin Binate-mangled forwards to libc.
//
// pkg/libc is always libc. On a libc-free target, code does NOT
// substitute a different libc_stubs.c — instead, that target uses
// a different pkg/builtins/rt that doesn't depend on pkg/libc at all.
//
// Naming: function "Foo" in package "pkg/libc" → symbol
// "bn_pkg__libc__Foo" (the standard Binate mangling).

#include <stdlib.h>
#include <stdint.h>

// Binate's `int` is target word-sized — see binate_runtime.c for the
// rationale.  The libc bridges below take and return Binate-int
// values, so their C signatures must use the same type so that the
// LLVM IR emitted by pkg/binate/codegen (which uses intLL() at these sites)
// links cleanly to the C symbol.
typedef intptr_t bn_int_t;

void *bn_pkg__libc__Malloc(bn_int_t size) {
    return malloc((size_t)size);
}

void *bn_pkg__libc__Calloc(bn_int_t count, bn_int_t size) {
    return calloc((size_t)count, (size_t)size);
}

void bn_pkg__libc__Free(void *ptr) {
    free(ptr);
}

void bn_pkg__libc__Exit(bn_int_t code) {
    exit((int)code);
}
