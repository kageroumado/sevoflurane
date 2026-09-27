#!/bin/zsh
# Empties a Debug build's Quick Look extension's content types, so the only thumbnail
# provider for Windows programs on the Mac is the installed app's.
#
# Xcode registers every app it builds with LaunchServices, and every Debug build carries
# the same extension identifier. With two registered copies, Quick Look can pick one whose
# identifier launchd already runs from another path: launchd reuses that instance, the
# request is never answered, and Finder shows a blank preview and holds the file open for a
# minute before it falls back to another provider. Worktrees and agents leave Debug builds
# behind by the dozen, so the only reliable rule is that a Debug build claims no file type.
#
# SEVO_DEBUG_THUMBNAIL=1 in the build environment keeps the types, for work on the
# thumbnails themselves; unregister that build (`lsregister -u <app>`) when done. Runs as
# the extension target's "Claim no types in Debug" build phase, after its Info.plist is
# processed and before the extension is signed.
set -euo pipefail

if [[ "${CONFIGURATION:-}" != "Debug" || "${SEVO_DEBUG_THUMBNAIL:-0}" == "1" ]]; then
    exit 0
fi

plist="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
key=":NSExtension:NSExtensionAttributes:QLSupportedContentTypes"
buddy=/usr/libexec/PlistBuddy
"$buddy" -c "Delete $key" "$plist" 2>/dev/null || true
"$buddy" -c "Add $key array" "$plist"
