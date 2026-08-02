#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>

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
// Bootstrap package — the print/println lowering's I/O sink (Write)
// ============================================================

// Write(fd int, buf *[]uint8) int — writes len(buf) bytes
bn_int_t bn_F2_3_pkg9_bootstrap1_5_Write(bn_int_t fd, BnSlice buf) {
    if (!buf.data || buf.len <= 0) return 0;
    ssize_t w = write((int)fd, buf.data, (size_t)buf.len);
    return (bn_int_t)w;
}

/* No `main` here: the process entry point (the C `main` symbol) and argv
 * capture are written in Binate — pkg/builtins/startup._entry, exported as the
 * unmangled `main` via #[c_export] and compiled into every hosted binary, which
 * captures argv and installs it via startup.SetArgs, then calls bn_entry (the
 * synthetic `<main>.__entry` the compiler emits, running per-package var
 * initializers then the user's main).  This runtime now provides only the
 * remaining hosted shim
 * (Write).  The frozen BUILDER-bundle copy of this file still defines
 * `main` + bootstrap.Args, for gen1 (which BUILDER links against); the version
 * gate on startup._entry keeps the two in lockstep.  See design-ffi-export.md
 * §3.3 and plan-build-version-predicate.md. */
