#!/bin/sh
set -eu
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_OPTIONAL_LOCKS=0
pfos_commit="$(/usr/bin/git -C "$SRCROOT" rev-parse --verify HEAD 2>/dev/null || true)"
if [ -z "$pfos_commit" ] && [ "${CI_XCODE_CLOUD:-}" = TRUE ]; then
    pfos_commit="${CI_COMMIT:-}"
fi
case "$pfos_commit" in
    *[!0-9a-fA-F]*|'') pfos_commit=unavailable ;;
esac
if [ "${#pfos_commit}" -ne 40 ]; then pfos_commit=unavailable; fi
pfos_dirty=unknown
if [ "$pfos_commit" != unavailable ]; then
    if pfos_changes="$(/usr/bin/git -C "$SRCROOT" status --porcelain --untracked-files=normal 2>/dev/null)"; then
        pfos_dirty=false
        if [ -n "$pfos_changes" ]; then pfos_dirty=true; fi
    fi
fi
pfos_generated="$SCRIPT_OUTPUT_FILE_0"
pfos_bundled="$SCRIPT_OUTPUT_FILE_1"
/bin/mkdir -p "$(/usr/bin/dirname "$pfos_generated")" "$(/usr/bin/dirname "$pfos_bundled")"
/bin/rm -f "$pfos_generated"
/usr/bin/plutil -create xml1 "$pfos_generated"
/usr/libexec/PlistBuddy -c "Add :PFOSGitCommit string $pfos_commit" "$pfos_generated"
if [ "$pfos_dirty" != unknown ]; then
    /usr/libexec/PlistBuddy -c "Add :PFOSGitDirty bool $pfos_dirty" "$pfos_generated"
fi
/bin/cp "$pfos_generated" "$pfos_bundled"
