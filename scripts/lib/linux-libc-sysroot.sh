# scripts/lib/linux-libc-sysroot.sh — sourced (not run) by the e2e scripts that link Linux
# ELF dynamically with bnld.  A dynamic ELF link reads libc.so.6's .dynsym to decide what the
# executable exports, so it needs the target's libc.so.6 on disk, found under a sysroot.
#
# linux_libc_sysroot <arch> <dir>: <arch> is x86_64 or aarch64.  Prints a sysroot under which
# an <arch> libc.so.6 lies, for bnld / bnc `--sysroot`, and returns 0; returns 1 when there is
# none (the caller SKIPs its dynamic links):
#   - a Linux host with an <arch> libc.so.6 in its own multiarch or lib64 directory: "/";
#   - otherwise, where Docker may be used (a Linux CI lane, or BINATE_E2E_DOCKER=1 locally)
#     and works: <dir>, holding lib/<arch>-linux-gnu/libc.so.6 copied out of the
#     debian:stable-slim image the e2e scripts run their programs in.
linux_libc_sysroot() {
    _lls_arch="$1"
    _lls_dir="$2"
    _lls_triple="$_lls_arch-linux-gnu"
    case "$_lls_arch" in
        x86_64) _lls_plat=linux/amd64 ;;
        aarch64) _lls_plat=linux/arm64 ;;
        *) return 1 ;;
    esac
    if [ "$(uname -s)" = Linux ]; then
        if [ -e "/lib/$_lls_triple/libc.so.6" ] || [ -e "/usr/lib/$_lls_triple/libc.so.6" ]; then
            echo /
            return 0
        fi
        if [ "$(uname -m)" = "$_lls_arch" ] && [ -e /lib64/libc.so.6 ]; then
            echo /
            return 0
        fi
    fi
    _lls_docker=0
    if [ -n "${CI:-}" ] && [ "$(uname -s)" = Linux ]; then _lls_docker=1; fi
    if [ "${BINATE_E2E_DOCKER:-0}" = 1 ]; then _lls_docker=1; fi
    [ "$_lls_docker" = 1 ] || return 1
    command -v docker > /dev/null 2>&1 || return 1
    mkdir -p "$_lls_dir/lib/$_lls_triple" || return 1
    _lls_cid="$(docker create --platform "$_lls_plat" debian:stable-slim 2> /dev/null)" || return 1
    docker cp -L "$_lls_cid:/lib/$_lls_triple/libc.so.6" "$_lls_dir/lib/$_lls_triple/libc.so.6" \
            > /dev/null 2>&1
    _lls_rc=$?
    docker rm "$_lls_cid" > /dev/null 2>&1 || true
    [ "$_lls_rc" = 0 ] || return 1
    echo "$_lls_dir"
}
