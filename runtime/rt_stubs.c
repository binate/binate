// rt_stubs.c — Thin C wrappers for libc functions used by pkg/rt.
// These have mangled names matching the Binate calling convention:
// function "foo" in package "pkg/rt" → symbol "bn_rt__foo".

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>
#include <unistd.h>

void *bn_rt__c_malloc(int64_t size) {
    return malloc((size_t)size);
}

void *bn_rt__c_calloc(int64_t count, int64_t size) {
    return calloc((size_t)count, (size_t)size);
}

void bn_rt__c_free(void *ptr) {
    free(ptr);
}

void bn_rt__c_memset(void *ptr, int64_t val, int64_t size) {
    memset(ptr, (int)val, (size_t)size);
}

void bn_rt__c_memcpy(void *dst, void *src, int64_t size) {
    memcpy(dst, src, (size_t)size);
}

void bn_rt__c_exit(int64_t code) {
    exit((int)code);
}

// Call a destructor function pointer: dtor(ptr).
void bn_rt__c_call_dtor(void *dtor, void *ptr) {
    typedef void (*dtor_fn)(void *);
    ((dtor_fn)dtor)(ptr);
}

// Formatted error + abort for bounds check failures (slow path only)
void bn_rt__c_bounds_fail(int64_t index, int64_t length) {
    fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
            (long long)index, (long long)length);
    abort();
}

// c_print_float — format a float64 with %g and write it to stdout
// via a direct write(2) syscall. The VM's int/bool/string print
// paths use write(2) directly (bypassing libc stdio), so mixing
// printf() in here caused the float output to sit in libc's buffer
// while later direct writes appeared first. Keeping everything on
// the write(2) side avoids the interleaving entirely. Called from
// pkg/rt; the Binate-side declaration is in pkg/rt.bni.
void bn_rt__c_print_float(double d) {
    char buf[32];
    int n = snprintf(buf, sizeof(buf), "%g", d);
    if (n < 0) return;
    if (n > (int)sizeof(buf) - 1) n = (int)sizeof(buf) - 1;
    ssize_t _ = write(1, buf, (size_t)n);
    (void)_;
}
