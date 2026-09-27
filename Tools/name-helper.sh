#!/bin/zsh
# Names the background helper after the app that carries it: the launchd label is
# `<bundle id>.daemon` and the associated bundle is the app's own. A Debug build's bundle
# id is glass.kagerou.sevoflurane.debug, so its helper registers under a label of its own
# and never replaces the installed app's registration, which macOS pins to the signature
# of whichever build registered it first. `AppIdentity` derives the same label in Swift.
#
# Runs as the app target's "Name the helper" build phase, after the helper's plist is
# copied into Contents/Library/LaunchAgents and before the bundle is signed.
set -euo pipefail

plist="$TARGET_BUILD_DIR/$WRAPPER_NAME/Contents/Library/LaunchAgents/SevofluraneDaemon.plist"
buddy=/usr/libexec/PlistBuddy
"$buddy" -c "Set :Label $PRODUCT_BUNDLE_IDENTIFIER.daemon" "$plist"
"$buddy" -c "Set :AssociatedBundleIdentifiers:0 $PRODUCT_BUNDLE_IDENTIFIER" "$plist"
