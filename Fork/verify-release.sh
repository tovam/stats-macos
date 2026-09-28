#!/bin/bash
set -euo pipefail

# Matches the contract checked by already-installed CompactUpdater versions.
test "$#" == 3 || { echo 'Usage: verify-release.sh APP TAG COMMIT' >&2; exit 1; }
release_app="$1"
release_tag="$2"
release_sha="$3"
test -n "$release_app" && test -d "$release_app" && test ! -L "$release_app"
test "${release_app##*/}" == 'Stats Compact.app'
[[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-statscompact\.[0-9]+$ ]]
[[ "$release_sha" =~ ^[0-9a-f]{40}$ ]]
release_plist="$release_app/Contents/Info.plist"

assert_value() {
    local actual
    actual="$(/usr/bin/plutil -extract "$1" raw -o - "$release_plist")"
    if [[ "$actual" != "$2" ]]; then
        echo "::error::Unexpected $1: $actual (expected $2)"
        exit 1
    fi
}

assert_value CFBundleIdentifier com.tovam.StatsCompact
assert_value CFBundleExecutable 'Stats Compact'
assert_value CompactReleaseRepository tovam/stats-macos
assert_value CompactReleaseTag "$release_tag"
assert_value CompactBuildSHA "$release_sha"
test -x "$release_app/Contents/MacOS/Stats Compact"
cmp Kit/scripts/updater.sh "$release_app/Contents/Resources/Scripts/updater.sh"
cmp Kit/scripts/compact/uninstall.sh "$release_app/Contents/Resources/Scripts/uninstall.sh"
echo "Auto-update bundle validated: $release_tag ($release_sha)"
