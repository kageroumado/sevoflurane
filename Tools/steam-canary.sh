#!/bin/zsh
# Audits the Steam client Valve is about to ship: downloads the public beta's
# steamui package from Valve's client-update servers, unpacks it into a new
# folder under /Volumes/Ugreen/Scratch/steam-canary/<date>/ and runs
# `sevo steam audit` on it. The beta leads the stable client by days, so what
# is missing here is what breaks when the beta goes stable.
#
#   Tools/steam-canary.sh [--stable]
#   SEVO=/path/to/sevo Tools/steam-canary.sh      a sevo other than the one on PATH
#
# The download is data: it is checked against the manifest's SHA-256, unpacked
# into its own folder, read, and never run. The only requests are the two GETs
# to Valve. Exits with the audit's status: 1 when a dependency is missing.
set -eu

host=https://client-update.steamstatic.com
manifest_name=steam_client_publicbeta_win64
[[ ${1:-} == --stable ]] && manifest_name=steam_client_win64
package=steamui_websrc_all
root=/Volumes/Ugreen/Scratch/steam-canary
sevo=${SEVO:-sevo}

[[ -d ${root:h} ]] || { print -u2 "${root:h} is not mounted"; exit 2; }
run=$root/$(date +%F)
[[ -e $run ]] && run=$run-$(date +%H%M%S)
mkdir -p $run
cd $run

curl --fail --silent --show-error --location --max-time 60 --max-filesize 1000000 \
    --output manifest.vdf $host/$manifest_name

# The manifest names the package's plain zip and its SHA-256. Both are read as
# text and held to their expected shapes before either is used.
block=$(awk -v name="\"$package\"" '$1 == name { inside = 1 } inside { print } inside && /}/ { exit }' manifest.vdf)
file=$(print -r -- $block | awk '$1 == "\"file\"" { gsub(/"/, "", $2); print $2 }')
sha=$(print -r -- $block | awk '$1 == "\"sha2\"" { gsub(/"/, "", $2); print $2 }')
version=$(awk '$1 == "\"version\"" { gsub(/"/, "", $2); print $2; exit }' manifest.vdf)
[[ $file =~ '^steamui_websrc_all\.zip\.[0-9a-f]{40}$' ]] || { print -u2 "the manifest names no $package zip"; exit 2; }
[[ $sha =~ '^[0-9a-f]{64}$' ]] || { print -u2 "the manifest gives no SHA-256 for $file"; exit 2; }
[[ $version =~ '^[0-9]+$' ]] || version=unknown

curl --fail --silent --show-error --location --max-time 600 --max-filesize 300000000 \
    --output package.zip $host/$file
[[ $(shasum -a 256 package.zip | cut -d' ' -f1) == $sha ]] || { print -u2 "$file does not match the manifest's SHA-256"; exit 2; }

# No entry may leave the folder it is unpacked into.
if unzip -Z1 package.zip | grep -q -E '(^/|(^|/)\.\.(/|$))'; then
    print -u2 "$file holds a path outside its folder"; exit 2
fi
mkdir package
unzip -q -o package.zip -d package
if [[ -n $(find package -type l -print -quit) ]]; then
    print -u2 "$file holds a symbolic link"; exit 2
fi
[[ -d package/steamui ]] || { print -u2 "$file holds no steamui folder"; exit 2; }

print "client $version ($manifest_name), package $file"
print "unpacked in $run/package/steamui"
result=0
$sevo steam audit --bundle $run/package/steamui --json > audit.json || result=$?
$sevo steam audit --bundle $run/package/steamui || true
print "every entry's answer: $run/audit.json"
exit $result
