#!/bin/sh
# Check that x86-64 ELF files ask for no more than the x86-64 baseline ISA.
#
# A linked program's .note.gnu.property can carry "x86 ISA needed" levels
# (x86-64-baseline, -v2, -v3, -v4); glibc's loader refuses to start a program
# whose levels the CPU lacks ("CPU ISA level is lower than required").  The
# linker ORs the levels of every input into the output, so one input built for a
# higher level -- the C startup objects of a build image compiled for
# x86-64-v3, say -- marks the whole program, whatever its own code needs.  The
# release's linux-x64 tools must run on any x86-64 CPU, so make-bundle.sh runs
# this on them.
#
# Usage: scripts/check-elf-isa.sh <file>...
# Exit status: 0 if every file needs at most x86-64-baseline (a file with no
# such note needs nothing), 1 if one needs more, 2 if no readelf is available.
set -u

READELF=""
for r in readelf llvm-readelf; do
    if command -v "$r" >/dev/null 2>&1; then
        READELF="$r"
        break
    fi
done
if [ -z "$READELF" ]; then
    echo "check-elf-isa: neither readelf nor llvm-readelf is on PATH" >&2
    exit 2
fi

status=0
for f in "$@"; do
    if ! notes="$("$READELF" -n "$f" 2>&1)"; then
        echo "check-elf-isa: $READELF cannot read $f: $notes" >&2
        status=1
        continue
    fi
    needed="$(printf '%s\n' "$notes" | sed -n 's/.*x86 ISA needed: *//p')"
    case "$needed" in
        "" | x86-64-baseline) ;;
        *)
            echo "check-elf-isa: $f needs $needed; only x86-64-baseline is allowed" >&2
            status=1
            ;;
    esac
done
exit $status
