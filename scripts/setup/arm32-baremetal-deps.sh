#!/bin/sh
# Install / verify the local-dev toolchain for the arm32-baremetal
# mode.
#
# The boot-comp_arm32_baremetal conformance + unit-test runners
# need:
#   - clang (host) with armv7a-none-eabi target support
#   - lld (LLVM linker) — clang's default linker on macOS / many
#     Linux distros can't link cross-target ELF without it
#   - qemu-system-arm (provides the `virt` machine model with
#     semihosting)
#
# On Linux this installs the missing pieces via apt.  On macOS it
# installs Homebrew's `llvm` (which ships lld) and `qemu`, and
# prints a one-liner for adding lld to PATH if Homebrew hasn't
# linked it globally.

set -e

os="$(uname -s)"

case "$os" in
    Linux)
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "error: this helper only supports apt-based distros."
            echo "       install equivalents for clang + lld +"
            echo "       qemu-system-arm manually."
            exit 1
        fi
        echo ">>> sudo apt-get update"
        sudo apt-get update
        echo ">>> sudo apt-get install ..."
        sudo apt-get install -y \
            clang \
            lld \
            qemu-system-arm
        ;;
    Darwin)
        if ! command -v brew >/dev/null 2>&1; then
            echo "error: Homebrew is required on macOS."
            echo "       https://brew.sh"
            exit 1
        fi
        echo ">>> brew install llvm qemu"
        brew install llvm qemu
        cat <<'EOF'

Homebrew's `lld` typically lands at
/opt/homebrew/opt/llvm/bin/ld.lld (Apple Silicon) or
/usr/local/opt/llvm/bin/ld.lld (Intel).  Apple's `clang` won't
find it on PATH by default; either add Homebrew's llvm to PATH:
    export PATH="$(brew --prefix llvm)/bin:$PATH"
or pass `--cflag -fuse-ld=lld` (with lld on PATH) to bnc.
EOF
        ;;
    *)
        echo "error: unsupported OS '$os'."
        exit 1
        ;;
esac

# Sanity-check the installed toolchain.
echo ">>> sanity check"
echo 'int main(void){return 0;}' \
    | clang -target armv7a-none-eabi -mfloat-abi=soft -ffreestanding -nostdlib -x c -c - -o /tmp/_bn_baremetal_probe.o
rm -f /tmp/_bn_baremetal_probe.o
if ! command -v qemu-system-arm >/dev/null 2>&1; then
    echo "error: qemu-system-arm not on PATH after install"
    exit 1
fi

echo "OK: clang cross-compile and qemu-system-arm are available."
