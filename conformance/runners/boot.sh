#!/bin/sh
# Runner: boot — the BUILDER_VERSION binary runs .bn directly.
# (BUILDER_VERSION currently names the bootstrap interpreter; once
# bnc-X.Y.Z releases ship, this runner will be renamed `builder`.)

runner_setup() {
    BOOT_BUILDER="$("$BINATE_DIR/scripts/fetch-builder.sh")"
}

runner_exec() {
    bn="$1"
    root="$2"
    if [ -n "$root" ]; then
        "$BOOT_BUILDER" -root "$root" -add-root "$BINATE_DIR" "$bn" 2>&1 || true
    else
        "$BOOT_BUILDER" -root "$BINATE_DIR" "$bn" 2>&1 || true
    fi
}

runner_cleanup() {
    : # nothing to clean up
}
