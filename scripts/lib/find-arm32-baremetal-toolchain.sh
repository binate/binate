#!/bin/sh
# Probe the host for the arm32-baremetal cross-link flags that clang/lld can't
# infer on their own.  Sourced by the bare-metal unit-test + conformance
# runners.
#
# Exports:
#   BAREMETAL_LD_FLAGS — extra clang flags piped through bnc's `--cflag`.
#                       Empty on Linux (system clang picks lld via
#                       gcc-toolchain discovery); `-fuse-ld=lld` on macOS
#                       where Apple's Mach-O `ld` would otherwise reject the
#                       ELF cross-link.
#
# The target's AEABI runtime helpers (__aeabi_ldivmod, the soft-float set, the
# 32-bit integer divides, ...) are provided in-tree by
# runtime/baremetal_arm32/aeabi_{int,float}.s, so no host arm-none-eabi libgcc.a
# is needed — the link is C-free.

case "$(uname -s)" in
    Darwin) BAREMETAL_LD_FLAGS="-fuse-ld=lld" ;;
    *)      BAREMETAL_LD_FLAGS="" ;;
esac
export BAREMETAL_LD_FLAGS
