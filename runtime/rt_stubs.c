// rt_stubs.c — Thin C wrappers for libc functions used by pkg/rt.
// These have mangled names matching the Binate calling convention:
// function "foo" in package "pkg/rt" → symbol "bn_rt__foo".

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

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
