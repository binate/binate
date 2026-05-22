#!/bin/sh
# Install / verify the local-dev toolchain for the arm32-linux mode.
#
# The boot-comp_arm32_linux conformance and unit-test runners need:
#   - clang (host) with cross-compile support for armv7-linux-gnueabihf
#   - ARM Linux cross-libc / linux-libc-dev sysroot
#   - qemu-user (qemu-arm or qemu-arm-static) for user-mode ELF
#     execution
#
# On Linux this installs the missing pieces via apt.  On macOS it
# prints guidance — no convenient native path exists; use a Linux
# Docker container or a Linux dev box.

set -e

os="$(uname -s)"

case "$os" in
    Linux)
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "error: this helper only supports apt-based distros."
            echo "       install equivalents for clang + libc6-armhf-cross"
            echo "       + libc6-dev-armhf-cross + linux-libc-dev-armhf-cross"
            echo "       + qemu-user-static manually."
            exit 1
        fi
        echo ">>> sudo apt-get update"
        sudo apt-get update
        echo ">>> sudo apt-get install ..."
        sudo apt-get install -y \
            clang \
            libc6-armhf-cross \
            libc6-dev-armhf-cross \
            linux-libc-dev-armhf-cross \
            qemu-user-static
        ;;
    Darwin)
        cat <<'EOF'
macOS has no convenient native cross-toolchain for arm32-linux
(Apple clang doesn't ship the Linux sysroot, and Homebrew doesn't
package one cleanly).  Two recommended options:

  1.  Run the boot-comp_arm32_linux runner inside a Linux container:
        docker run --rm -it -v "$PWD":/work -w /work ubuntu:24.04 \
            sh -c "scripts/setup/arm32-linux-deps.sh && \
                   conformance/run.sh boot-comp_arm32_linux"

  2.  Use a Linux dev VM / SSH host and run the same commands there.

Once one of those is set up, no further configuration is needed; the
runner auto-detects qemu-arm / qemu-arm-static.
EOF
        exit 0
        ;;
    *)
        echo "error: unsupported OS '$os'."
        exit 1
        ;;
esac

# Sanity-check the installed toolchain.
echo ">>> sanity check"
echo 'int main(void){return 0;}' \
    | clang -target armv7-linux-gnueabihf -x c -c - -o /tmp/_bn_arm32_probe.o
rm -f /tmp/_bn_arm32_probe.o
qemu_arm=""
if command -v qemu-arm-static >/dev/null 2>&1; then
    qemu_arm=qemu-arm-static
elif command -v qemu-arm >/dev/null 2>&1; then
    qemu_arm=qemu-arm
fi
if [ -z "$qemu_arm" ]; then
    echo "error: qemu-arm not on PATH after install"
    exit 1
fi

echo "OK: clang cross-compile and $qemu_arm are available."
