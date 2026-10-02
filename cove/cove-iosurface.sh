#!/usr/bin/env bash
# Resolve the public IOSurface request to kitty's presence-only implementation
# flag. This file is sourced by the launchers; it does not run on its own.

cove_normalize_iosurface() {
    local requested
    case "${COVE_IOSURFACE:-0}" in
    0|"") requested=0 ;;
    1) requested=1 ;;
    *)
        echo "COVE_IOSURFACE must be 0 or 1 (got ${COVE_IOSURFACE})." >&2
        return 2
        ;;
    esac

    # These are launcher state, not part of a termling's shell environment.
    unset COVE_IOSURFACE COVE_IOSURFACE_RESOLVED
    COVE_IOSURFACE=$requested
    COVE_IOSURFACE_RESOLVED=0
    unset KITTY_COVE_IOSURFACE
}

cove_probe_iosurface() {
    local probe_output
    [ "$COVE_IOSURFACE" = 1 ] || return 0

    # Godot discovers a new GDExtension during project import. Do that once when
    # its registration cache is absent, then ask Godot itself whether the class
    # is usable. A dylib on disk is not enough evidence that it loaded.
    if [ ! -f "$APP/.godot/extension_list.cfg" ] \
            || ! grep -Fxq 'res://cove.gdextension' "$APP/.godot/extension_list.cfg"; then
        "$GODOT" --path "$APP" --editor --headless --quit >/dev/null 2>&1 || true
    fi
    probe_output=""
    if probe_output=$("$GODOT" --headless --path "$APP" \
            --script res://scripts/IOSurfaceProbe.gd --quit-after 2 2>&1) \
            && printf '%s\n' "$probe_output" | grep -Fxq 'COVE_IOSURFACE_PROBE=1'; then
        COVE_IOSURFACE_RESOLVED=1
        export KITTY_COVE_IOSURFACE=1
        echo "cove: IOSurface transport enabled (CoveIOSurface class available)." >&2
    else
        echo "warning: COVE_IOSURFACE=1 requested, but CoveIOSurface is unavailable; using file transport." >&2
    fi
}

cove_resolve_iosurface() {
    cove_normalize_iosurface
    cove_probe_iosurface
}

cove_write_iosurface_env() {
    printf 'COVE_IOSURFACE=%s\n' "$COVE_IOSURFACE"
    printf 'COVE_IOSURFACE_RESOLVED=%s\n' "$COVE_IOSURFACE_RESOLVED"
}
