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

# The newest stable release (dormison-r<N>) that carries its signature, by version number.
tarball=""
for candidate in "$releases"/dormison-r<->.tar.xz(Nn); do
    [[ -f "$candidate.sig" ]] && tarball="$candidate"
done
if [[ -z "$tarball" ]]; then
    echo "warning: no signed dormison-r<N>.tar.xz in $releases; the app will download its engine"
    exit 0
fi

mkdir -p "$destination"
# The folder holds one engine: an older one left from an earlier build would ship too.
rsync -a --delete --include "$(basename "$tarball")" --include "$(basename "$tarball").sig" --exclude '*' \
    "$releases/" "$destination/"
echo "embedded $(basename "$tarball") ($(du -h "$tarball" | cut -f1)) in the app"
