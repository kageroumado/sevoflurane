#!/bin/zsh
# The app target's "Boundary lint" phase: checks the view/logic boundary
# (Tools/BoundaryLint, CONTRIBUTING.md) and prints file:line diagnostics Xcode
# marks in the editor. Fails the build only on violations past baseline.json.
#
# The tool builds beside the app's DerivedData and rebuilds only when its own
# sources are newer than the binary. A tool that cannot build (offline on a
# fresh clone: swift-syntax is fetched once) warns and lets the build go on.
set -u

lint="$SRCROOT/Tools/BoundaryLint"
scratch="${BUILD_DIR%/Build/*}/BoundaryLint"
tool="$scratch/release/boundary-lint"

if [[ ! -x "$tool" || -n "$(find "$lint/Package.swift" "$lint/Sources" -newer "$tool" -print -quit)" ]]; then
    mkdir -p "$scratch"
    # A clean environment: Xcode's build settings would steer SwiftPM's own build.
    if ! env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        xcrun swift build --package-path "$lint" --scratch-path "$scratch" \
        -c release --product boundary-lint > "$scratch/build.log" 2>&1; then
        echo "warning: BoundaryLint did not build (see $scratch/build.log); the boundary is unchecked this build"
        exit 0
    fi
fi

exec "$tool" --root "$SRCROOT"
