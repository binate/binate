// libc_stubs.c — Implements the bn_pkg__builtins__libc__* symbols declared by
// pkg/builtins/libc.bni: thin Binate-mangled forwards to libc.
//
// pkg/builtins/libc is always libc. On a libc-free target, code does NOT
// substitute a different libc_stubs.c — instead, that target uses
// a different pkg/builtins/rt that doesn't depend on pkg/builtins/libc at all.
//
// Naming: function "Foo" in package "pkg/builtins/libc" → symbol
// "bn_pkg__builtins__libc__Foo" (the standard Binate mangling).

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// Binate's `int` is target word-sized — see binate_runtime.c for the
// rationale.  The libc bridges below take and return Binate-int
// values, so their C signatures must use the same type so that the
// LLVM IR emitted by pkg/binate/codegen (which uses intLL() at these sites)
// links cleanly to the C symbol.
typedef intptr_t bn_int_t;

void *bn_pkg__builtins__libc__Malloc(bn_int_t size) {
    return malloc((size_t)size);
}

void *bn_pkg__builtins__libc__Calloc(bn_int_t count, bn_int_t size) {
    return calloc((size_t)count, (size_t)size);
}

void bn_pkg__builtins__libc__Free(void *ptr) {
    free(ptr);
}

void bn_pkg__builtins__libc__Memset(void *ptr, bn_int_t val, bn_int_t size) {
    memset(ptr, (int)val, (size_t)size);
}

void bn_pkg__builtins__libc__Memcpy(void *dst, const void *src, bn_int_t size) {
    memcpy(dst, src, (size_t)size);
}

void bn_pkg__builtins__libc__Exit(bn_int_t code) {
    exit((int)code);
}

// Compat aliases: the previous symbol names (`bn_pkg__libc__*`)
// before pkg/libc was moved into pkg/builtins/libc.  BUILDER
// (bnc-<=0.0.6) compiles checkout source by reading its own snapshot
// of pkg/binate/codegen — which emits hardcoded `bn_pkg__libc__Memcpy`
// calls for memcpy lowering (visible in `strings` output of the
// BUILDER bnc binary).  Aliases keep that path linkable until
// BUILDER_VERSION is bumped to a release whose codegen emits the new
// names natively.  Remove this block once BUILDER_VERSION is on a
// release that emits `bn_pkg__builtins__libc__*` natively.
void *bn_pkg__libc__Malloc(bn_int_t size)
    __attribute__((alias("bn_pkg__builtins__libc__Malloc")));
void *bn_pkg__libc__Calloc(bn_int_t count, bn_int_t size)
    __attribute__((alias("bn_pkg__builtins__libc__Calloc")));
void bn_pkg__libc__Free(void *ptr)
    __attribute__((alias("bn_pkg__builtins__libc__Free")));
void bn_pkg__libc__Memset(void *ptr, bn_int_t val, bn_int_t size)
    __attribute__((alias("bn_pkg__builtins__libc__Memset")));
void bn_pkg__libc__Memcpy(void *dst, const void *src, bn_int_t size)
    __attribute__((alias("bn_pkg__builtins__libc__Memcpy")));
void bn_pkg__libc__Exit(bn_int_t code)
    __attribute__((alias("bn_pkg__builtins__libc__Exit")));
