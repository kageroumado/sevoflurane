#!/bin/zsh
# Puts the engine inside the app: the signed Dormison tarball a fresh install would download,
# with its `.sig`, in Contents/Resources/Engine, where first-run setup installs it without a
# download (EngineInstaller.bundledTarball) and a newer app hands its newer engine over at
# launch (EngineStore). Later engines arrive as releases from the manifest.
#
# Runs as the app target's "Embed engine" build phase, in Release builds only. The releases
# come from `publish-engine.sh` (a real run or `--dry-run`) in $DORMISON_BUILD/releases,
# or SEVO_ENGINE_RELEASES; SEVO_EMBED_ENGINE=0 builds an app without one. A build with no
# signed release there embeds nothing and says so: the app then downloads its engine.
set -euo pipefail

if [[ "${CONFIGURATION:-}" != "Release" || "${SEVO_EMBED_ENGINE:-1}" == "0" ]]; then
    exit 0
fi

releases="${SEVO_ENGINE_RELEASES:-${DORMISON_BUILD:-$HOME/Developer/build/dormison}/releases}"
destination="$BUILT_PRODUCTS_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Engine"

# The engine a fresh install would download: the manifest's `stable` release. The highest
# number on disk can be an older series the manifest no longer names. Without a manifest, the
# newest signed dormison-b<N> or dormison-r<N> in the app's order (Engine.isOlderVersion:
# dormison-r10 < dormison-b11 < dormison-r11).
tarball=$(/usr/bin/python3 - "$releases" <<'PY'
import json, os, re, sys

releases = sys.argv[1]

def order(version):
    match = re.fullmatch(r"dormison-([rb])(\d+)", version)
    return (int(match.group(2)), match.group(1) == "r") if match else (-1, False)

def signed(version):
    path = os.path.join(releases, version + ".tar.xz")
    return path if os.path.isfile(path) and os.path.isfile(path + ".sig") else None

names = []
try:
    with open(os.path.join(releases, "engine.json")) as manifest:
        channels = json.load(manifest)["channels"]
    names = [channels["stable"]["version"]]
except (OSError, ValueError, KeyError):
    names = [entry[: -len(".tar.xz")] for entry in os.listdir(releases) if entry.endswith(".tar.xz")] \
        if os.path.isdir(releases) else []
    names = [name for name in names if order(name)[0] >= 0 and signed(name)]
if names:
    newest = max(names, key=order)
    print(signed(newest) or "")
PY
)
if [[ -z "$tarball" ]]; then
    echo "warning: no signed dormison-b<N>.tar.xz or dormison-r<N>.tar.xz in $releases; the app will download its engine"
    exit 0
fi

mkdir -p "$destination"
# The folder holds one engine: an older one left from an earlier build would ship too.
rsync -a --delete --delete-excluded --include "$(basename "$tarball")" --include "$(basename "$tarball").sig" --exclude '*' \
    "$releases/" "$destination/"
echo "embedded $(basename "$tarball") ($(du -h "$tarball" | cut -f1)) in the app"
