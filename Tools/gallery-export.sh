#!/bin/bash
# Writes the Debug UI gallery to PNG strips: every settings pane, popover state
# and first-run step, from fixtures, touching nothing on this Mac. Each
# Settings pane is also pane-<name>.png, each first-run screen in each state
# setup-<number>-<screen>-<state>.png, the popover that leads back
# setup-popover-<state>.png and each cause of the panel about a run view-run-<cause>.png.
#   Tools/gallery-export.sh <output directory> [derived data path]
# SEVO_GALLERY_APPEARANCE=dark in the environment writes the dark appearance.
set -euo pipefail
out=${1:?output directory}
derived=${2:-"$HOME/Developer/build/sevoflurane-dd"}
mkdir -p "$out"
SEVO_GALLERY=1 SEVO_GALLERY_EXPORT="$(cd "$out" && pwd)" \
    "$derived/Build/Products/Debug/Sevoflurane.app/Contents/MacOS/Sevoflurane" 2>&1 | grep 'gallery export'
