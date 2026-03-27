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
// Managed pointers (box)
// ============================================================

// box(val) — allocate val_size bytes on heap, copy val into it
void *bn_box(void *val, int64_t val_size) {
    void *ptr = malloc((size_t)val_size);
    if (!ptr) {
        fprintf(stderr, "runtime error: out of memory\n");
        exit(2);
    }
    memcpy(ptr, val, (size_t)val_size);
    return ptr;
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
