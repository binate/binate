#!/bin/sh
# e2e/arm32-mixed-backend-calls.sh — e2e/mixed-backend-calls.sh on arm32-linux
# (hard-float): a dependency package compiled by one backend and the program by the
# other, cross-compiled for arm32, linked with arm-linux-gnueabihf-gcc and run under
# qemu-arm.  arm32 hard-float places HFAs, multi-value returns and float shims by its
# own AAPCS-VFP rules, which both backends must agree on.
#
# Auto-discovered by .github/workflows/e2e-tests.yml — the `arm32` name prefix gates
# in qemu-user-static + gcc-arm-linux-gnueabihf on the Linux runner.  SKIPs unless that
# toolchain is present; skips on macOS via the .skip.darwin marker.

MIXED_TARGET=arm32-linux exec "$(dirname "$0")/mixed-backend-calls.sh"
