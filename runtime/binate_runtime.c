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

// Write(fd int, buf *[]uint8) int — writes len(buf) bytes
bn_int_t bn_F2_3_pkg9_bootstrap1_5_Write(bn_int_t fd, BnSlice buf) {
    if (!buf.data || buf.len <= 0) return 0;
    ssize_t w = write((int)fd, buf.data, (size_t)buf.len);
    return (bn_int_t)w;
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

/* No `main` here: the process entry point (the C `main` symbol) and argv
 * capture are written in Binate — pkg/builtins/startup._entry, exported as the
 * unmangled `main` via #[c_export] and compiled into every hosted binary, which
 * captures argv and installs it via startup.SetArgs, then calls bn_entry (the
 * synthetic `<main>.__entry` the compiler emits, running per-package var
 * initializers then the user's main).  This runtime now provides only the
 * remaining hosted shims
 * (Write, Exec).  The frozen BUILDER-bundle copy of this file still defines
 * `main` + bootstrap.Args, for gen1 (which BUILDER links against); the version
 * gate on startup._entry keeps the two in lockstep.  See design-ffi-export.md
 * §3.3 and plan-build-version-predicate.md. */
