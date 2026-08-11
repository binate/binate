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
// I/O and process: all bn_* shims have been removed. OP_PANIC lowers
// to rt.Panic, which writes the message through rt's own sink and
// Aborts (__c_call("abort") on a hosted target, a nonzero semihost
// exit on a libc-free one).
// ============================================================

// ============================================================
// Bootstrap package — the Write I/O sink
// ============================================================

// Write(fd int, buf *[]uint8) int — writes len(buf) bytes
bn_int_t bn_F2_3_pkg9_bootstrap1_5_Write(bn_int_t fd, BnSlice buf) {
    if (!buf.data || buf.len <= 0) return 0;
    ssize_t w = write((int)fd, buf.data, (size_t)buf.len);
    return (bn_int_t)w;
}

/* No `main` here: the process entry point (the C `main` symbol) is written in
 * Binate — `pkg/builtins/startup._entry`, `#[c_export("main")]` (emitted under
 * the unmangled `main` that crt0 calls) and gated `#[build(is(entrypoint,
 * "main"))]`, so a hosted program gets exactly this one `main` and no collision.
 * It captures argv/envp, installs them via startup.SetArgs / SetEnv, then calls
 * bn_entry (the synthesized `main.__init_all(); main.main()`).  This runtime now
 * provides only the remaining hosted shim (Write). */
