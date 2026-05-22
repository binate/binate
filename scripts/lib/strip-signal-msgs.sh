# strip_signal_msgs filters out-of-band signal-death diagnostics
# from a captured runner output stream so silent-SEGV tests get
# the same `actual` across macOS dev (where these messages don't
# appear) and Linux CI (where they do).  Three sources of noise:
#
#   - the shell (dash, bash) prints "Segmentation fault" /
#     "Segmentation fault (core dumped)" on a child's signal
#     death (Linux only).
#   - qemu-user prints "qemu: uncaught target signal N (Foo) -
#     core dumped" when its guest dies on a signal.  Hits every
#     arm32-linux SEGV test even though the guest binary itself
#     produced no extra output.  Variant suffix (`qemu-arm:`,
#     `qemu-aarch64-static:`) is also stripped.
#   - GNU `timeout` (used by the arm32 runners to cap wall-clock)
#     prints "the monitored command dumped core" when it observes
#     SIGSEGV (its own postscript, separate from the guest's).
#
# Sourced by conformance/run.sh and tested by
# scripts/hygiene/strip-signal-msgs.sh.
strip_signal_msgs() {
    printf '%s\n' "$1" | grep -Ev \
        '^(Segmentation fault|Killed|Aborted|Bus error|Floating point exception|Trace/breakpoint trap)( \(core dumped\))?$|^qemu(-[^:]*)?: uncaught target signal .*$|^timeout: the monitored command dumped core$' \
        | awk 'BEGIN { first = 1 } { if (!first) printf "\n"; printf "%s", $0; first = 0 }'
}
