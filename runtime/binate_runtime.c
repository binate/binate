#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>

// Binate runtime library
// Provides I/O and basic operations for compiled Binate programs.

// ============================================================
// Slice representation: { data*, len }
//
// Binate slices have no capacity field — append always reallocates.
// Unmanaged slices ([]T) own their data.
// Managed slices (@[]T) will add a refcount header later.
// ============================================================

typedef struct {
    void    *data;
    int64_t  len;
} BnSlice;

// make([]T, n) — allocate a zeroed slice with given length and element size
BnSlice bn_make_slice(int64_t elem_size, int64_t length) {
    BnSlice s;
    s.len = length;
    if (length > 0) {
        s.data = calloc((size_t)length, (size_t)elem_size);
    } else {
        s.data = NULL;
    }
    return s;
}

// len(s) — returns slice length (0 for nil)
int64_t bn_slice_len(BnSlice s) {
    return s.len;
}

// s[i] for i64 elements — returns element value
int64_t bn_slice_get_i64(BnSlice s, int64_t index) {
    if (index < 0 || index >= s.len) {
        fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
                (long long)index, (long long)s.len);
        exit(2);
    }
    return ((int64_t *)s.data)[index];
}

// s[i] = v for i64 elements
void bn_slice_set_i64(BnSlice s, int64_t index, int64_t val) {
    if (index < 0 || index >= s.len) {
        fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
                (long long)index, (long long)s.len);
        exit(2);
    }
    ((int64_t *)s.data)[index] = val;
}

// s[i] for i8 (char/byte) elements
int64_t bn_slice_get_i8(BnSlice s, int64_t index) {
    if (index < 0 || index >= s.len) {
        fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
                (long long)index, (long long)s.len);
        exit(2);
    }
    return (int64_t)(((uint8_t *)s.data)[index]);
}

// s[i] = v for i8 (char/byte) elements
void bn_slice_set_i8(BnSlice s, int64_t index, int64_t val) {
    if (index < 0 || index >= s.len) {
        fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
                (long long)index, (long long)s.len);
        exit(2);
    }
    ((uint8_t *)s.data)[index] = (uint8_t)val;
}

// append(s, v) for i64 elements — always reallocates (no capacity)
BnSlice bn_append_i64(BnSlice s, int64_t val) {
    int64_t newlen = s.len + 1;
    void *newdata = realloc(s.data, (size_t)newlen * sizeof(int64_t));
    if (!newdata) {
        fprintf(stderr, "runtime error: out of memory\n");
        exit(2);
    }
    ((int64_t *)newdata)[s.len] = val;
    s.data = newdata;
    s.len = newlen;
    return s;
}

// append(s, v) for i8 elements — always reallocates (no capacity)
BnSlice bn_append_i8(BnSlice s, int64_t val) {
    int64_t newlen = s.len + 1;
    void *newdata = realloc(s.data, (size_t)newlen);
    if (!newdata) {
        fprintf(stderr, "runtime error: out of memory\n");
        exit(2);
    }
    ((uint8_t *)newdata)[s.len] = (uint8_t)val;
    s.data = newdata;
    s.len = newlen;
    return s;
}

// Free slice backing data (no-op for nil slices)
void bn_slice_free(BnSlice s) {
    if (s.data) {
        free(s.data);
    }
}

// string literal → []char slice (copies string data, excludes null terminator)
BnSlice bn_string_to_chars(const char *str) {
    int64_t n = (int64_t)strlen(str);
    BnSlice s;
    s.len = n;
    if (n > 0) {
        s.data = malloc((size_t)n);
        memcpy(s.data, str, (size_t)n);
    } else {
        s.data = NULL;
    }
    return s;
}

// s[lo:hi] for i8 elements — sub-slice (copies data for safety)
BnSlice bn_slice_expr_i8(BnSlice s, int64_t lo, int64_t hi) {
    if (lo < 0 || hi < lo || hi > s.len) {
        fprintf(stderr, "runtime error: slice bounds out of range [%lld:%lld] (len %lld)\n",
                (long long)lo, (long long)hi, (long long)s.len);
        exit(2);
    }
    BnSlice r;
    r.len = hi - lo;
    if (r.len > 0) {
        r.data = malloc((size_t)r.len);
        memcpy(r.data, (uint8_t *)s.data + lo, (size_t)r.len);
    } else {
        r.data = NULL;
    }
    return r;
}

// s[lo:hi] for i64 elements — sub-slice (copies data for safety)
BnSlice bn_slice_expr_i64(BnSlice s, int64_t lo, int64_t hi) {
    if (lo < 0 || hi < lo || hi > s.len) {
        fprintf(stderr, "runtime error: slice bounds out of range [%lld:%lld] (len %lld)\n",
                (long long)lo, (long long)hi, (long long)s.len);
        exit(2);
    }
    BnSlice r;
    r.len = hi - lo;
    if (r.len > 0) {
        r.data = malloc((size_t)r.len * sizeof(int64_t));
        memcpy(r.data, ((int64_t *)s.data) + lo, (size_t)r.len * sizeof(int64_t));
    } else {
        r.data = NULL;
    }
    return r;
}

// Print []char slice as string
void bn_print_chars(BnSlice s) {
    if (s.data && s.len > 0) {
        fwrite(s.data, 1, (size_t)s.len, stdout);
    }
}

// ============================================================
// Managed pointers — refcounted with two-word header
//
// Layout: [ refcount (int64) | free_fn (ptr) | payload ... ]
//                                              ^
//                               managed pointer points here
//
// refcount at ptr[-2], free_fn at ptr[-1]
// free_fn is called with the base pointer (ptr - 16) when refcount hits 0
// ============================================================

#define BN_HEADER_SIZE (2 * sizeof(int64_t))
#define BN_REFCOUNT_IMMORTAL INT64_MAX

typedef void (*bn_free_fn)(void *base);

// Default free function — just calls free on the base pointer
static void bn_default_free(void *base) {
    free(base);
}

// bn_alloc — allocate managed memory with refcount header
// Returns pointer to payload (past the two-word header)
void *bn_alloc(int64_t payload_size) {
    void *base = malloc(BN_HEADER_SIZE + (size_t)payload_size);
    if (!base) {
        fprintf(stderr, "runtime error: out of memory\n");
        exit(2);
    }
    int64_t *header = (int64_t *)base;
    header[0] = 1;                          // refcount = 1
    header[1] = (int64_t)bn_default_free;   // free function
    void *payload = (void *)(header + 2);
    memset(payload, 0, (size_t)payload_size);
    return payload;
}

// box(val) — allocate val_size bytes on heap with refcount header, copy val into payload
void *bn_box(void *val, int64_t val_size) {
    void *payload = bn_alloc(val_size);
    memcpy(payload, val, (size_t)val_size);
    return payload;
}

// Increment refcount of a managed pointer (no-op for nil)
void bn_refcount_inc(void *ptr) {
    if (!ptr) return;
    int64_t *header = ((int64_t *)ptr) - 2;
    if (header[0] == BN_REFCOUNT_IMMORTAL) return;
    header[0]++;
}

// Decrement refcount of a managed pointer; free if it hits zero (no-op for nil)
void bn_refcount_dec(void *ptr) {
    if (!ptr) return;
    int64_t *header = ((int64_t *)ptr) - 2;
    if (header[0] == BN_REFCOUNT_IMMORTAL) return;
    header[0]--;
    if (header[0] <= 0) {
        bn_free_fn fn = (bn_free_fn)header[1];
        fn((void *)header);
    }
}

// ============================================================
// Bounds checking
// ============================================================

void bn_bounds_check(int64_t index, int64_t length) {
    if (index < 0 || index >= length) {
        fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
                (long long)index, (long long)length);
        exit(2);
    }
}

// ============================================================
// I/O
// ============================================================

void bn_print_string(const char *s) {
    fputs(s, stdout);
}

void bn_print_int(int64_t n) {
    printf("%lld", (long long)n);
}

void bn_print_bool(int8_t b) {
    if (b) {
        printf("true");
    } else {
        printf("false");
    }
}

void bn_print_newline(void) {
    printf("\n");
}

void bn_exit(int64_t code) {
    exit((int)code);
}

/* Entry point: calls Binate's main function */
extern void bn_main(void);

int main(void) {
    bn_main();
    return 0;
}
