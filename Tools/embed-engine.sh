#!/bin/zsh
# Puts the engine inside the app: the newest signed Dormison release tarball, with its
# `.sig`, in Contents/Resources/Engine, where first-run setup installs it without a
# download (EngineInstaller.bundledTarball) and a newer app hands its newer engine over at
# launch (EngineStore). Later engines still arrive through the release channel.
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

# The release the manifest names as stable, which is what a fresh install would download;
# the highest number on disk can be an older series that manifest no longer names.
# Without a manifest, the newest signed dormison-r<N> by version number.
tarball=""
stable=""
if [[ -f "$releases/engine.json" ]]; then
    stable=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["channels"]["stable"]["version"])' "$releases/engine.json" 2>/dev/null || true)
fi
if [[ -n "$stable" ]]; then
    [[ -f "$releases/$stable.tar.xz" && -f "$releases/$stable.tar.xz.sig" ]] && tarball="$releases/$stable.tar.xz"
else
    for candidate in "$releases"/dormison-r<->.tar.xz(Nn); do
        [[ -f "$candidate.sig" ]] && tarball="$candidate"
    done
fi
if [[ -z "$tarball" ]]; then
    echo "warning: no signed dormison-r<N>.tar.xz in $releases; the app will download its engine"
    exit 0
fi

mkdir -p "$destination"
# The folder holds one engine: an older one left from an earlier build would ship too.
rsync -a --delete --include "$(basename "$tarball")" --include "$(basename "$tarball").sig" --exclude '*' \
    "$releases/" "$destination/"
echo "embedded $(basename "$tarball") ($(du -h "$tarball" | cut -f1)) in the app"
