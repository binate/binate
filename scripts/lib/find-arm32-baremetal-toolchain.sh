#!/bin/sh
# Probe the host for the arm32-baremetal cross-toolchain bits that
# clang/lld can't find on their own.  Sourced by the bare-metal
# unit-test + conformance runners.
#
# Exports:
#   BAREMETAL_LIBGCC_A — absolute path to libgcc.a from the host's
#                       arm-none-eabi GCC install.  bnc receives it
#                       via `--link-after-objs`; lld pulls AEABI
#                       helpers (__aeabi_ldivmod etc.) from it.
#   BAREMETAL_LD_FLAGS — extra clang flags piped through bnc's
#                       `--cflag`.  Empty on Linux (system clang
#                       picks lld via gcc-toolchain discovery);
#                       `-fuse-ld=lld` on macOS where Apple's
#                       Mach-O `ld` would otherwise reject the
#                       ELF cross-link.
#
# Probe order on Linux: the apt-installed /usr/lib/gcc/<...>/libgcc.a
# (CI's path); on macOS: the Homebrew arm-none-eabi-gcc Cellar.
#
# On miss, BAREMETAL_LIBGCC_A is left empty — the caller should
# surface that as a missing-prereq error.

probe_arm32_libgcc() {
    # Probe order: apt (Linux/CI), then arm64-mac brew, then x64-mac
    # brew.  Each entry is `<gcc-root>|<lib-subpath>`: <gcc-root> is
    # the toolchain prefix (apt/brew install location); <lib-subpath>
    # is the relative position of the per-version `lib/gcc/<triple>/`
    # tree.  We then enumerate the version dirs and take the
    # shortest libgcc.a path (the default multilib, sitting directly
    # under <ver>/) rather than a sibling like `<ver>/thumb/v7-m/...`
    # which would mismatch our `-march=armv7-a -mfloat-abi=soft`
    # ARM-mode link.  Skip a probe if its root doesn't exist (so
    # find doesn't print a noisy error on mismatched hosts).
    for entry in \
        '/usr/lib/gcc|arm-none-eabi' \
        '/opt/homebrew/Cellar/arm-none-eabi-gcc|gcc/lib/gcc/arm-none-eabi' \
        '/usr/local/Cellar/arm-none-eabi-gcc|gcc/lib/gcc/arm-none-eabi'; do
        prefix="${entry%%|*}"
        sub="${entry#*|}"
        [ -d "$prefix" ] || continue
        # For brew, the gcc-root itself has a version dir (e.g.
        # `10.3-2021.07/`); enumerate at depth 1.  For apt the
        # `prefix` IS the gcc-root.
        case "$prefix" in
            */Cellar/*) gcc_roots=$(find "$prefix" -mindepth 1 -maxdepth 1 -type d 2>/dev/null) ;;
            *)          gcc_roots="$prefix" ;;
        esac
        for gr in $gcc_roots; do
            tree="$gr/$sub"
            [ -d "$tree" ] || continue
            # find libgcc.a directly under each <ver>/ subdir; the
            # default multilib lives at <ver>/libgcc.a (no further
            # nesting).
            for ver in "$tree"/*; do
                if [ -f "$ver/libgcc.a" ]; then
                    echo "$ver/libgcc.a"
                    return 0
                fi
            done
        done
    done
    return 1
}

BAREMETAL_LIBGCC_A="$(probe_arm32_libgcc)"
case "$(uname -s)" in
    Darwin) BAREMETAL_LD_FLAGS="-fuse-ld=lld" ;;
    *)      BAREMETAL_LD_FLAGS="" ;;
esac
export BAREMETAL_LIBGCC_A BAREMETAL_LD_FLAGS
