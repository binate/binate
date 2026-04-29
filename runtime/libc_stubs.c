// libc_stubs.c — Implements the bn_libc__* symbols declared by
// pkg/libc.bni: thin Binate-mangled forwards to libc.
//
// pkg/libc is always libc. On a libc-free target, code does NOT
// substitute a different libc_stubs.c — instead, that target uses
// a different pkg/rt that doesn't depend on pkg/libc at all.
//
// Naming: function "Foo" in package "pkg/libc" → symbol
// "bn_libc__Foo" (the standard Binate mangling).

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

void *bn_libc__Malloc(int64_t size) {
    return malloc((size_t)size);
}

void *bn_libc__Calloc(int64_t count, int64_t size) {
    return calloc((size_t)count, (size_t)size);
}

void bn_libc__Free(void *ptr) {
    free(ptr);
}

void bn_libc__Memset(void *ptr, int64_t val, int64_t size) {
    memset(ptr, (int)val, (size_t)size);
}

void bn_libc__Memcpy(void *dst, const void *src, int64_t size) {
    memcpy(dst, src, (size_t)size);
}

void bn_libc__Exit(int64_t code) {
    exit((int)code);
}
