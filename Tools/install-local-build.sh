#!/bin/zsh
# Installs the DMG that `kagerou publish sevoflurane --dry-run` left behind:
# quits the running app (Steam closes with it), replaces the bundle in
# /Applications, reopens it and waits for a healthy client.
set -euo pipefail

dmg="$HOME/Library/Application Support/Rilmazafone/Releases/Sevoflurane/$(ls -t "$HOME/Library/Application Support/Rilmazafone/Releases/Sevoflurane" | grep -m1 '\.dmg$')"
app="/Applications/Sevoflurane.app"
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "installing $dmg"
if pgrep -f "$app/Contents/MacOS/Sevoflurane$" >/dev/null; then
    osascript -e 'tell application "Sevoflurane" to quit'
    while pgrep -f "$app/Contents/MacOS/Sevoflurane$" >/dev/null; do sleep 1; done
fi

volume=$(hdiutil attach -nobrowse -readonly "$dmg" 2>/dev/null | awk -F'\t' '/Volumes/{print $3}')
[ -d "$app" ] && trash "$app"
cp -R "$volume/Sevoflurane.app" /Applications/
hdiutil detach "$volume" -quiet

# The archive leaves a second copy of the thumbnail extension registered
# under one identifier, and runningboardd then launches neither. By its
# resolved path: DerivedData can be a symlink onto another volume, and
# `lsregister -u` leaves the record in place when handed the linked path.
for stale in "$HOME"/Library/Developer/Xcode/DerivedData/Sevoflurane-*/Build/Intermediates.noindex/ArchiveIntermediates/Sevoflurane/InstallationBuildProductsLocation/Applications/Sevoflurane.app(N); do
    "$lsregister" -u "${stale:A}" 2>/dev/null || true
done

spctl -a -vv "$app" 2>&1 | head -2
open "$app"
"$app/Contents/Helpers/sevo" wait --timeout 240 | tail -1
