#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>

// Binate runtime library
// Provides I/O and basic operations for compiled Binate programs.

// Binate's `int` type is the target word-sized signed integer (8
// bytes on LP64, 4 bytes on 32-bit ARM Linux ILP32).  Every C field /
// function arg / return value here that represents a Binate `int`
// uses `bn_int_t`, so the C ABI tracks the LLVM IR emitted by
// pkg/binate/codegen (which uses intLL() at the same sites).
typedef intptr_t bn_int_t;

// ============================================================
// Slice representation: { data*, len }
//
// Unmanaged slices (*[]T): { *T data, uint len } — no capacity, append always reallocates.
// Managed slices (@[]T): { *T data, uint len, @any refptr } — provided by pkg/builtins/rt.
// ============================================================

typedef struct {
    void    *data;      // *T: pointer to first element
    bn_int_t  len;       // uint: number of elements
} BnSlice;

typedef struct {
    void    *data;       // *T: pointer to first element
    bn_int_t  len;        // uint: number of elements
    void    *backing;    // managed backing pointer (refcounted)
    bn_int_t  backing_len; // total element count in backing
} BnManagedSlice;

// Managed memory (Alloc, Box, RefInc, RefDec, Free) and bounds checking
// are provided by pkg/builtins/rt. See pkg/builtins/rt/rt.bn; rt calls libc
// directly via __c_call (no separate stub file).

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
    r.len = (bn_int_t)strlen(s);
    if (r.len > 0) {
        r.data = malloc((size_t)r.len);
        memcpy(r.data, s, (size_t)r.len);
    } else {
        r.data = NULL;
    }
    return r;
}

// Helper: allocate a managed block (header + payload, refcount=1).
// Header is 2 * sizeof(bn_int_t) — 16 bytes on LP64, 8 bytes on
// 32-bit ARM Linux.  Layout: [refcount, free_fn_ptr] both bn_int_t.
// free_fn_ptr is left as 0 — the sentinel pkg/builtins/rt.Free reads as
// "default = RawFree" and dispatches directly without going through
// `_call_free_fn`.  Avoids the bootstrap circularity where the C
// runtime would otherwise need a function-value handle whose layout
// is tied to whichever bnc compiled the consumer (Phase 4 handle
// vs. pre-Phase-4 raw fn ptr).
static void *managed_alloc(size_t payload_size) {
    void *base = calloc(1, 2 * sizeof(bn_int_t) + payload_size);
    bn_int_t *header = (bn_int_t *)base;
    header[0] = 1;  // refcount = 1
    header[1] = 0;  // default free fn = RawFree (see rt.Free)
    return (char *)base + 2 * sizeof(bn_int_t);  // return pointer past header
}

// Helper: convert C string to BnManagedSlice of chars
static BnManagedSlice cstr_to_managed_slice(const char *s) {
    BnManagedSlice r;
    r.len = (bn_int_t)strlen(s);
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

// Write(fd int, buf *[]uint8) int — writes len(buf) bytes
bn_int_t bn_F2_3_pkg9_bootstrap1_5_Write(bn_int_t fd, BnSlice buf) {
    if (!buf.data || buf.len <= 0) return 0;
    ssize_t w = write((int)fd, buf.data, (size_t)buf.len);
    return (bn_int_t)w;
}

// Exit(code int)
void bn_F2_3_pkg9_bootstrap1_4_Exit(bn_int_t code) {
    exit((int)code);
}

// Store argc/argv for Args()
static int bn_argc = 0;
static char **bn_argv = NULL;

// Args() @[]@[]char
BnManagedSlice bn_F2_3_pkg9_bootstrap1_4_Args(void) {
    BnManagedSlice result;
    bn_int_t count = bn_argc > 1 ? bn_argc - 1 : 0;
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
bn_int_t bn_F2_3_pkg9_bootstrap1_4_Exec(BnSlice program, BnSlice args) {
    char *prog = slice_to_cstr(program);

    // Build argv: [program, args..., NULL]
    // args is *[]@[]char — each element is a BnManagedSlice (4 words).
    // We extract the {data, len} prefix from each for slice_to_cstr.
    bn_int_t nargs = args.len;
    char **argv = (char **)malloc((size_t)(nargs + 2) * sizeof(char *));
    argv[0] = prog;
    for (bn_int_t i = 0; i < nargs; i++) {
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
    for (bn_int_t i = 0; i <= nargs; i++) {
        free(argv[i]);
    }
    free(argv);

    if (WIFEXITED(status)) {
        return (bn_int_t)WEXITSTATUS(status);
    }
    return -1;
}

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
