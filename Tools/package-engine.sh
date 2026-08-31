#!/bin/zsh
# package-engine.sh — assembles a managed-engine tarball + manifest entry
# (release-plan R2.2; layout consumed by Engine.swift / EngineInstaller.swift).
#
#   Tools/package-engine.sh --version wine11.16-dxmt0.80-r1 [options]
#
# Payloads and their sources:
#   wine/       Gcenx macOS_Wine_builds (WineHQ official macOS binaries)
#   dxmt/       3Shain/dxmt "builtin" release (open source)
#   dxvk/       Gcenx/DXVK-macOS "builtin" release (zlib license)
#   d3dmetal/   Apple Game Porting Toolkit — no public URL; pass
#               --gptk <dir> pointing at the mounted GPTk `lib/` directory.
#               Apple's license allows non-commercial redistribution with the
#               license text riding along; it is copied in as LICENSE.
#
# --from-crossover copies dxvk/dxmt/d3dmetal payloads out of the local
# CrossOver install instead of downloading. FOR LOCAL TESTING ONLY — never
# redistribute a tarball built this way (CodeWeavers' builds are theirs).
#
# Output: sevo-engine-<version>.tar.xz + a ready-to-paste engine.json entry.

set -euo pipefail

WINE_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.16/wine-staging-11.16-osx64.tar.xz"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
DXVK_URL="https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz"
CX="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"

VERSION=""
GPTK_DIR=""
FROM_CROSSOVER=0
OUT_DIR="$PWD"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --wine-url) WINE_URL="$2"; shift 2 ;;
        --dxmt-url) DXMT_URL="$2"; shift 2 ;;
        --dxvk-url) DXVK_URL="$2"; shift 2 ;;
        --gptk) GPTK_DIR="$2"; shift 2 ;;
        --from-crossover) FROM_CROSSOVER=1; shift ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

[[ -n "$VERSION" ]] || { echo "--version is required (e.g. wine11.16-dxmt0.80-r1)" >&2; exit 2; }

TOOLS_DIR="${0:a:h}"
WORK="$(mktemp -d /tmp/sevo-engine.XXXXXX)"
trap 'trash "$WORK" 2>/dev/null || true' EXIT
ROOT="$WORK/$VERSION"
mkdir -p "$ROOT"

step() { print -P "%F{cyan}==>%f $1"; }

step "wine: $WINE_URL"
curl -fsSL "$WINE_URL" -o "$WORK/wine.tar.xz"
mkdir -p "$WORK/wine-extract"
tar -xf "$WORK/wine.tar.xz" -C "$WORK/wine-extract"
WINE_RES=$(echo "$WORK"/wine-extract/*.app/Contents/Resources/wine)
[[ -d "$WINE_RES" ]] || { echo "no wine tree inside the Gcenx tarball" >&2; exit 1; }
cp -R "$WINE_RES" "$ROOT/wine"
[[ -x "$ROOT/wine/bin/wine64" || -x "$ROOT/wine/bin/wine" ]] \
    || { echo "wine binary missing after extract" >&2; exit 1; }

step "game category: tagging the wine loader for native Game Mode"
# A Wine game's window belongs to the loader process; tagging it
# public.app-category.games (+GCSupportsGameMode) lets macOS engage Game Mode
# on its own when the game is full screen — no gamepolicyctl, no entitlement.
# Only the loaders host game windows; wineserver never does.
if ! python3 -c 'import lief' 2>/dev/null; then
    print -P "%F{yellow}   installing LIEF (packaging-time only)…%f"
    python3 -m pip install --quiet lief \
        || { echo "LIEF needed to tag the loader (pip install lief)" >&2; exit 1; }
fi
for loader in wine wine64 wineloader wine-preloader wine64-preloader; do
    bin="$ROOT/wine/bin/$loader"
    [[ -f "$bin" && ! -L "$bin" ]] || continue
    python3 "$TOOLS_DIR/embed-game-category.py" "$bin"
    codesign -f -s - "$bin"
done

if [[ $FROM_CROSSOVER -eq 1 ]]; then
    step "dxmt/dxvk/d3dmetal from local CrossOver (LOCAL TESTING ONLY)"
    mkdir -p "$ROOT/dxmt" "$ROOT/dxvk" "$ROOT/d3dmetal"
    cp -R "$CX/lib/dxmt/x86_64-windows/." "$ROOT/dxmt/"
    cp -R "$CX/lib/dxvk/x86_64-windows/." "$ROOT/dxvk/"
    mkdir -p "$ROOT/wine/lib/wine/x86_64-unix"
    cp -R "$CX/lib/dxmt/x86_64-unix/." "$ROOT/wine/lib/wine/x86_64-unix/" 2>/dev/null || true
    cp -R "$CX/lib64/apple_gptk/external/." "$ROOT/d3dmetal/"
    cp -R "$CX/lib64/apple_gptk/wine/x86_64-windows/." "$ROOT/d3dmetal/" 2>/dev/null || true
    cp "$CX/lib64/apple_gptk/external/D3DMetal.framework/Versions/A/Resources/LICENSE" \
        "$ROOT/d3dmetal/LICENSE" 2>/dev/null || true
    echo "from-crossover" > "$ROOT/DO-NOT-REDISTRIBUTE"
else
    step "dxmt: $DXMT_URL"
    mkdir -p "$WORK/dxmt-extract" "$ROOT/dxmt"
    curl -fsSL "$DXMT_URL" -o "$WORK/dxmt.tar.gz"
    tar -xf "$WORK/dxmt.tar.gz" -C "$WORK/dxmt-extract"
    find "$WORK/dxmt-extract" -name '*.dll' -path '*x86_64*' -exec cp {} "$ROOT/dxmt/" \;
    find "$WORK/dxmt-extract" -name '*.so' -path '*x86_64*' \
        -exec cp {} "$ROOT/wine/lib/wine/x86_64-unix/" \; 2>/dev/null || true

    step "dxvk: $DXVK_URL"
    mkdir -p "$WORK/dxvk-extract" "$ROOT/dxvk"
    curl -fsSL "$DXVK_URL" -o "$WORK/dxvk.tar.gz"
    tar -xf "$WORK/dxvk.tar.gz" -C "$WORK/dxvk-extract"
    find "$WORK/dxvk-extract" -name '*.dll' \( -path '*x64*' -o -path '*x86_64*' \) \
        -exec cp {} "$ROOT/dxvk/" \;

    if [[ -n "$GPTK_DIR" ]]; then
        step "d3dmetal: $GPTK_DIR"
        mkdir -p "$ROOT/d3dmetal"
        cp -R "$GPTK_DIR/external/." "$ROOT/d3dmetal/" 2>/dev/null \
            || cp -R "$GPTK_DIR/." "$ROOT/d3dmetal/"
        [[ -e "$ROOT/d3dmetal/D3DMetal.framework" ]] \
            || { echo "no D3DMetal.framework under --gptk path" >&2; exit 1; }
        LICENSE_PATH="$ROOT/d3dmetal/D3DMetal.framework/Versions/A/Resources/LICENSE"
        [[ -f "$LICENSE_PATH" ]] && cp "$LICENSE_PATH" "$ROOT/d3dmetal/LICENSE"
        [[ -f "$ROOT/d3dmetal/LICENSE" ]] \
            || { echo "GPTk LICENSE must ride along — not found" >&2; exit 1; }
    else
        step "d3dmetal: skipped (no --gptk; DXMT is the default renderer)"
    fi
fi

step "engine-info.json"
cat > "$ROOT/engine-info.json" <<EOF
{
  "version": "$VERSION",
  "wine": "$WINE_URL",
  "dxmt": "$([[ $FROM_CROSSOVER -eq 1 ]] && echo from-crossover || echo "$DXMT_URL")",
  "dxvk": "$([[ $FROM_CROSSOVER -eq 1 ]] && echo from-crossover || echo "$DXVK_URL")",
  "d3dmetal": "$([[ $FROM_CROSSOVER -eq 1 ]] && echo from-crossover || echo "${GPTK_DIR:-absent}")"
}
EOF

step "tarball"
TARBALL="$OUT_DIR/sevo-engine-$VERSION.tar.xz"
tar -cJf "$TARBALL" -C "$WORK" "$VERSION"
SHA256=$(shasum -a 256 "$TARBALL" | cut -d' ' -f1)
SIZE=$(stat -f%z "$TARBALL")

print -P "%F{green}done:%f $TARBALL"
cat <<EOF

engine.json entry (upload both to the "engine" release on GitHub):

{
  "schema": 1,
  "channels": {
    "stable": {
      "version": "$VERSION",
      "minAppVersion": "0.1.0",
      "url": "https://github.com/kageroumado/sevoflurane/releases/download/engine/sevo-engine-$VERSION.tar.xz",
      "sha256": "$SHA256",
      "sizeBytes": $SIZE,
      "notes": ""
    }
  }
}
EOF
