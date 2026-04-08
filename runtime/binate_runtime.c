#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <dirent.h>
#include <sys/wait.h>

// Binate runtime library
// Provides I/O and basic operations for compiled Binate programs.

// ============================================================
// Slice representation: { data*, len }
//
// Unmanaged slices ([]T): { *T data, uint len } — no capacity, append always reallocates.
// Managed slices (@[]T): { *T data, uint len, @any refptr } — provided by pkg/rt.
// ============================================================

typedef struct {
    void    *data;      // *T: pointer to first element
    int64_t  len;       // uint: number of elements
} BnSlice;

typedef struct {
    void    *data;       // *T: pointer to first element
    int64_t  len;        // uint: number of elements
    void    *backing;    // managed backing pointer (refcounted)
    int64_t  backing_len; // total element count in backing
} BnManagedSlice;

// make_raw_deprecated([]T, n) — allocate a zeroed unmanaged slice
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

// s[i] for struct elements — returns pointer to element in-place
void *bn_slice_get_struct(BnSlice s, int64_t index, int64_t elem_size) {
    if (index < 0 || index >= s.len) {
        fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
                (long long)index, (long long)s.len);
        exit(2);
    }
    return (char *)s.data + index * elem_size;
}

// s[i] = v for struct elements — copies elem_size bytes from ptr
void bn_slice_set_struct(BnSlice s, int64_t index, void *ptr, int64_t elem_size) {
    if (index < 0 || index >= s.len) {
        fprintf(stderr, "runtime error: index out of bounds: %lld (len %lld)\n",
                (long long)index, (long long)s.len);
        exit(2);
    }
    memcpy((char *)s.data + index * elem_size, ptr, (size_t)elem_size);
}

// Free slice backing data (no-op for nil slices)
void bn_slice_free(BnSlice s) {
    if (s.data) {
        free(s.data);
    }
}

// string literal → []char slice (copies string data)
BnSlice bn_string_to_chars(const char *str, int64_t len) {
    BnSlice s;
    s.len = len;
    if (len > 0) {
        s.data = malloc((size_t)len);
        memcpy(s.data, str, (size_t)len);
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

// s[lo:hi] for struct elements — sub-slice (copies data for safety)
BnSlice bn_slice_expr_struct(BnSlice s, int64_t lo, int64_t hi, int64_t elem_size) {
    if (lo < 0 || hi < lo || hi > s.len) {
        fprintf(stderr, "runtime error: slice bounds out of range [%lld:%lld] (len %lld)\n",
                (long long)lo, (long long)hi, (long long)s.len);
        exit(2);
    }
    BnSlice r;
    r.len = hi - lo;
    if (r.len > 0) {
        r.data = malloc((size_t)r.len * (size_t)elem_size);
        memcpy(r.data, (char *)s.data + lo * elem_size, (size_t)r.len * (size_t)elem_size);
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

// Managed memory (Alloc, Box, RefInc, RefDec, Free) and bounds checking
// are provided by pkg/rt. See pkg/rt/rt.bn and runtime/rt_stubs.c.

// ============================================================
// I/O
// ============================================================

void bn_print_string(const char *s, int64_t len) {
    if (s && len > 0) {
        fwrite(s, 1, (size_t)len, stdout);
    }
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
    fflush(stdout);
}

void bn_exit(int64_t code) {
    exit((int)code);
}

// ============================================================
// Bootstrap package — file I/O, process, string operations
// ============================================================

// Helper: convert BnSlice of chars to null-terminated C string
static char *slice_to_cstr(BnSlice s) {
    char *buf = (char *)malloc((size_t)s.len + 1);
    if (s.data && s.len > 0) {
        memcpy(buf, s.data, (size_t)s.len);
    }
    buf[s.len] = '\0';
    return buf;
}

// Helper: convert C string to BnSlice of chars (null-terminated C strings only)
static BnSlice cstr_to_slice(const char *s) {
    BnSlice r;
    r.len = (int64_t)strlen(s);
    if (r.len > 0) {
        r.data = malloc((size_t)r.len);
        memcpy(r.data, s, (size_t)r.len);
    } else {
        r.data = NULL;
    }
    return r;
}

// Open(path []char, flags int) int
int64_t bn_bootstrap__Open(BnSlice path, int64_t flags) {
    char *cpath = slice_to_cstr(path);
    int oflags = 0;
    int mode = flags & 3;  // low 2 bits: 0=RDONLY, 1=WRONLY, 2=RDWR
    if (mode == 0) oflags = O_RDONLY;
    else if (mode == 1) oflags = O_WRONLY;
    else if (mode == 2) oflags = O_RDWR;
    // Handle combined flags
    if (flags & 64)  oflags |= O_CREAT;
    if (flags & 512) oflags |= O_TRUNC;
    if (flags & 1024) oflags |= O_APPEND;
    int fd = open(cpath, oflags, 0644);
    free(cpath);
    return (int64_t)fd;
}

// Read(fd int, buf []uint8, n int) int
int64_t bn_bootstrap__Read(int64_t fd, BnSlice buf, int64_t n) {
    if (!buf.data || n <= 0) return 0;
    if (n > buf.len) n = buf.len;
    ssize_t r = read((int)fd, buf.data, (size_t)n);
    return (int64_t)r;
}

// Write(fd int, buf []uint8, n int) int
int64_t bn_bootstrap__Write(int64_t fd, BnSlice buf, int64_t n) {
    if (!buf.data || n <= 0) return 0;
    if (n > buf.len) n = buf.len;
    ssize_t w = write((int)fd, buf.data, (size_t)n);
    return (int64_t)w;
}

// Close(fd int) int
int64_t bn_bootstrap__Close(int64_t fd) {
    return (int64_t)close((int)fd);
}

// ReadDir(path []char) [][]char
BnSlice bn_bootstrap__ReadDir(BnSlice path) {
    char *cpath = slice_to_cstr(path);
    DIR *dir = opendir(cpath);
    free(cpath);

    BnSlice result;
    result.data = NULL;
    result.len = 0;

    if (!dir) return result;

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue; // skip hidden and . / ..
        BnSlice name = cstr_to_slice(entry->d_name);
        // Append BnSlice to result (slice of slices, each element is sizeof(BnSlice))
        int64_t newlen = result.len + 1;
        result.data = realloc(result.data, (size_t)newlen * sizeof(BnSlice));
        ((BnSlice *)result.data)[result.len] = name;
        result.len = newlen;
    }
    closedir(dir);
    return result;
}

// Stat(path []char) int  — returns 0=not found, 1=file, 2=directory
int64_t bn_bootstrap__Stat(BnSlice path) {
    char *cpath = slice_to_cstr(path);
    struct stat st;
    if (stat(cpath, &st) != 0) {
        free(cpath);
        return 0;
    }
    free(cpath);
    if (S_ISDIR(st.st_mode)) return 2;
    return 1;
}

// Exit(code int)
void bn_bootstrap__Exit(int64_t code) {
    exit((int)code);
}

// Store argc/argv for Args()
static int bn_argc = 0;
static char **bn_argv = NULL;

// Args() [][]char
BnSlice bn_bootstrap__Args(void) {
    BnSlice result;
    result.data = NULL;
    result.len = 0;

    // Skip program name (argv[0])
    for (int i = 1; i < bn_argc; i++) {
        BnSlice arg = cstr_to_slice(bn_argv[i]);
        int64_t newlen = result.len + 1;
        result.data = realloc(result.data, (size_t)newlen * sizeof(BnSlice));
        ((BnSlice *)result.data)[result.len] = arg;
        result.len = newlen;
    }
    return result;
}

// Exec(program []char, args [][]char) int
int64_t bn_bootstrap__Exec(BnSlice program, BnSlice args) {
    char *prog = slice_to_cstr(program);

    // Build argv: [program, args..., NULL]
    // args is []@[]char — each element is a BnManagedSlice (4 words).
    // We extract the {data, len} prefix from each for slice_to_cstr.
    int64_t nargs = args.len;
    char **argv = (char **)malloc((size_t)(nargs + 2) * sizeof(char *));
    argv[0] = prog;
    for (int64_t i = 0; i < nargs; i++) {
        BnManagedSlice ms = ((BnManagedSlice *)args.data)[i];
        BnSlice arg;
        arg.data = ms.data;
        arg.len = ms.len;
        argv[i + 1] = slice_to_cstr(arg);
    }
    argv[nargs + 1] = NULL;

    pid_t pid = fork();
    if (pid == 0) {
        execvp(prog, argv);
        _exit(127);
    }

    int status = 0;
    waitpid(pid, &status, 0);

    // Clean up
    for (int64_t i = 0; i <= nargs; i++) {
        free(argv[i]);
    }
    free(argv);

    if (WIFEXITED(status)) {
        return (int64_t)WEXITSTATUS(status);
    }
    return -1;
}

// alloc_managed_chars allocates a managed char buffer with refcount header.
// Returns a BnManagedSlice where data and backing both point to the payload.
static BnManagedSlice alloc_managed_chars(int64_t len) {
    BnManagedSlice ms;
    ms.len = len;
    ms.backing_len = len;
    if (len > 0) {
        // Header: [refcount, free_fn] then payload
        int64_t *base = (int64_t *)calloc(1, (size_t)(2 * sizeof(int64_t) + len));
        base[0] = 1;  // refcount = 1
        base[1] = 0;  // free_fn = null
        void *payload = &base[2];
        ms.data = payload;
        ms.backing = payload;
    } else {
        ms.data = NULL;
        ms.backing = NULL;
    }
    return ms;
}

// Itoa(v int) @[]char
BnManagedSlice bn_bootstrap__Itoa(int64_t v) {
    char buf[32];
    snprintf(buf, sizeof(buf), "%lld", (long long)v);
    int64_t len = (int64_t)strlen(buf);
    BnManagedSlice ms = alloc_managed_chars(len);
    if (len > 0) {
        memcpy(ms.data, buf, (size_t)len);
    }
    return ms;
}

// Concat(a []char, b []char) @[]char
BnManagedSlice bn_bootstrap__Concat(BnSlice a, BnSlice b) {
    int64_t len = a.len + b.len;
    BnManagedSlice ms = alloc_managed_chars(len);
    if (len > 0) {
        if (a.data && a.len > 0) memcpy(ms.data, a.data, (size_t)a.len);
        if (b.data && b.len > 0) memcpy((char *)ms.data + a.len, b.data, (size_t)b.len);
    }
    return ms;
}

/* Entry point: calls Binate's main function */
extern void bn_main(void);

int main(int argc, char **argv) {
    bn_argc = argc;
    bn_argv = argv;
    bn_main();
    return 0;
}
