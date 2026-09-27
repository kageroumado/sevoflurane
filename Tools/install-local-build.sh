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

# Every other registered copy of the app goes, the archive's first: it leaves a
# second copy of the thumbnail extension under the shipping identifier, and Quick
# Look then picks one it cannot launch and fails every .exe preview. The copies
# come from LaunchServices' own records, because the archive's folder is gone by
# now and a record outlives its folder; `lsregister -u` takes the path either way.
"$lsregister" -dump 2>/dev/null \
    | sed -nE 's/^path: +(.*\/Sevoflurane[^/]*\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u \
    | grep -vx "$app" \
    | while IFS= read -r stale; do "$lsregister" -u "$stale" 2>/dev/null || true; done || true

spctl -a -vv "$app" 2>&1 | head -2
open "$app"
"$app/Contents/Helpers/sevo" wait --timeout 240 | tail -1
