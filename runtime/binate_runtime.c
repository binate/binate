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
// Unmanaged slices (*[]T): { *T data, uint len } — no capacity, append always reallocates.
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

// Managed memory (Alloc, Box, RefInc, RefDec, Free) and bounds checking
// are provided by pkg/rt. See pkg/rt/rt.bn and runtime/libc_stubs.c
// (libc bridges).

// ============================================================
// I/O and process: all bn_* shims have been removed. Print/println's
// IR-gen now lowers each type through bootstrap.formatX (where
// needed) + bootstrap.Write. OP_PANIC lowers to rt.Exit (which
// currently wraps c_exit; on a libc-free target this would route
// through a syscall stub instead). See
// explorations/plan-print-builtin-runtime-decoupling.md.
// ============================================================

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

// Forward decl: pkg/rt's RawFree, used as the free_fn in headers
// allocated through this C-side helper. pkg/rt.Free reads header[1]
// and dispatches indirect through it (via OP_CALL_INDIRECT). Setting
// it here keeps managed allocations created in C consistent with
// those created via rt.Alloc — both are released through RawFree.
extern void bn_rt__RawFree(void *ptr);

// Helper: allocate a managed block (16-byte header + payload, refcount=1)
static void *managed_alloc(size_t payload_size) {
    void *base = calloc(1, 16 + payload_size);
    int64_t *header = (int64_t *)base;
    header[0] = 1;  // refcount = 1
    header[1] = (int64_t)(intptr_t)&bn_rt__RawFree;  // free_fn = &RawFree
    return (char *)base + 16;  // return pointer past header
}

// Helper: convert C string to BnManagedSlice of chars
static BnManagedSlice cstr_to_managed_slice(const char *s) {
    BnManagedSlice r;
    r.len = (int64_t)strlen(s);
    if (r.len > 0) {
        r.data = managed_alloc((size_t)r.len);
        memcpy(r.data, s, (size_t)r.len);
        r.backing = r.data;
        r.backing_len = r.len;
    } else {
        r.data = NULL;
        r.backing = NULL;
        r.backing_len = 0;
    }
    return r;
}

// Open(path *[]char, flags int) int
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

// Read(fd int, buf *[]uint8) int — reads up to len(buf) bytes
int64_t bn_bootstrap__Read(int64_t fd, BnSlice buf) {
    if (!buf.data || buf.len <= 0) return 0;
    ssize_t r = read((int)fd, buf.data, (size_t)buf.len);
    return (int64_t)r;
}

// Write(fd int, buf *[]uint8) int — writes len(buf) bytes
int64_t bn_bootstrap__Write(int64_t fd, BnSlice buf) {
    if (!buf.data || buf.len <= 0) return 0;
    ssize_t w = write((int)fd, buf.data, (size_t)buf.len);
    return (int64_t)w;
}

// Close(fd int) int
int64_t bn_bootstrap__Close(int64_t fd) {
    return (int64_t)close((int)fd);
}

// ReadDir(path *[]char) @[]@[]char
BnManagedSlice bn_bootstrap__ReadDir(BnSlice path) {
    char *cpath = slice_to_cstr(path);
    DIR *dir = opendir(cpath);
    free(cpath);

    BnManagedSlice result;
    result.data = NULL;
    result.len = 0;
    result.backing = NULL;
    result.backing_len = 0;

    if (!dir) return result;

    // First pass: count entries
    int64_t count = 0;
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        count++;
    }
    if (count == 0) { closedir(dir); return result; }

    // Allocate managed backing for the outer slice
    size_t elem_size = sizeof(BnManagedSlice);
    void *backing = managed_alloc(count * elem_size);
    BnManagedSlice *elems = (BnManagedSlice *)backing;

    // Second pass: fill entries
    rewinddir(dir);
    int64_t idx = 0;
    while ((entry = readdir(dir)) != NULL) {
        if (entry->d_name[0] == '.') continue;
        if (idx < count) {
            elems[idx] = cstr_to_managed_slice(entry->d_name);
            idx++;
        }
    }
    closedir(dir);

    result.data = backing;
    result.len = idx;
    result.backing = backing;
    result.backing_len = idx;
    return result;
}

// Stat(path *[]char) int  — returns 0=not found, 1=file, 2=directory
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

// Args() @[]@[]char
BnManagedSlice bn_bootstrap__Args(void) {
    BnManagedSlice result;
    int64_t count = bn_argc > 1 ? bn_argc - 1 : 0;
    if (count == 0) {
        result.data = NULL;
        result.len = 0;
        result.backing = NULL;
        result.backing_len = 0;
        return result;
    }
    size_t elem_size = sizeof(BnManagedSlice);
    void *backing = managed_alloc(count * elem_size);
    BnManagedSlice *elems = (BnManagedSlice *)backing;
    for (int i = 0; i < count; i++) {
        elems[i] = cstr_to_managed_slice(bn_argv[i + 1]);
    }
    result.data = backing;
    result.len = count;
    result.backing = backing;
    result.backing_len = count;
    return result;
}

// Exec(program *[]char, args *[]*[]char) int
int64_t bn_bootstrap__Exec(BnSlice program, BnSlice args) {
    char *prog = slice_to_cstr(program);

    // Build argv: [program, args..., NULL]
    // args is *[]@[]char — each element is a BnManagedSlice (4 words).
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

// bn_bootstrap__Itoa and bn_bootstrap__Concat have moved to
// pkg/bootstrap/bootstrap.bn — pure Binate, no C dependency.
// (Their former alloc_managed_chars helper was deleted with them.)

/* Entry point: dispatch into Binate.  `bn_entry` is the linker
 * symbol the per-binary entry wrapper emits under (a synthetic
 * `<main>.__entry` Binate function generated by cmd/bnc); it
 * runs per-package var initializers and then calls the user's
 * main.  Keeping all entry-time semantics behind one stable
 * symbol means future entry-time concerns (panic / signal setup,
 * etc.) live in Binate without further C-runtime churn. */
extern void bn_entry(void);

int main(int argc, char **argv) {
    bn_argc = argc;
    bn_argv = argv;
    bn_entry();
    return 0;
}
