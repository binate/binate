// rt_stubs.c — Thin C wrappers for libc functions used by pkg/rt.
// These have mangled names matching the Binate calling convention:
// function "foo" in package "pkg/rt" → symbol "bn_rt__foo".

#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

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

// Formatted error + abort for bounds check failures (slow path only)
void bn_rt__c_bounds_fail(int64_t index, int64_t length) {
    fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
            (long long)index, (long long)length);
    exit(2);
}
