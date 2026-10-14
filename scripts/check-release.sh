#!/bin/zsh
# Checks that Info.plist, RELEASE_NOTES.md and the dist/ artifacts are ready to publish:
# built from the committed HEAD, matching version and build, Developer ID team, hardened runtime,
# universal, notarized and stapled.
# With --metadata it checks only Info.plist and the notes (CI runs that).
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
team="${FOLIO_TEAM_ID:-28LJG7MXT3}"
fail() { print -u2 "release-check: $*"; exit 1 }
info() { /usr/libexec/PlistBuddy -c "Print :$1" "${2:-Info.plist}" }
version="$(info CFBundleShortVersionString)"
build="$(info CFBundleVersion)"
[[ "$version" =~ '^[0-9]+\.[0-9]+$' ]] || fail "CFBundleShortVersionString must look like 1.5 (<major>.<build>), not $version"
[[ "$build" == <1-> ]] || fail "CFBundleVersion must be a positive integer, not $build"
[[ "$(info CFBundleIdentifier)" == org.lumashelf.app ]] || fail 'Keep the bundle identifier org.lumashelf.app'
grep -qF "**$version**" RELEASE_NOTES.md || fail "RELEASE_NOTES.md must name **$version**"
grep -qE '^## (New|Improvements|Fixes)$' RELEASE_NOTES.md || fail 'RELEASE_NOTES.md needs a New, Improvements or Fixes section'
! grep -q 'folio-build:' RELEASE_NOTES.md || fail 'Remove the build marker from RELEASE_NOTES.md; the publisher adds it'
[[ "${version#*.}" == "$build" ]] || fail "The version's second number must equal the build: $version vs build $build; run scripts/bump-version.sh"
print "Metadata: Folio $version"
[[ "${1:-}" != --metadata ]] || exit 0

dmg=dist/Folio.dmg
zip="dist/Folio-$version.zip"
[[ -f "$dmg" && -f "$zip" && -f dist/SHA256SUMS.txt ]] || fail "Missing $dmg, $zip or dist/SHA256SUMS.txt; run make dmg"
(cd dist && shasum -a 256 -c SHA256SUMS.txt >/dev/null) || fail 'dist/SHA256SUMS.txt does not match the artifacts'
head="$(git rev-parse HEAD)"
work="$(mktemp -d /private/tmp/folio-check.XXXXXX)"
mount=""
cleanup() {
  [[ -z "$mount" ]] || hdiutil detach "$mount" -force >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

check_app() {
  local app="$1" signature archs
  [[ "$(info CFBundleShortVersionString "$app/Contents/Info.plist")" == "$version" &&
     "$(info CFBundleVersion "$app/Contents/Info.plist")" == "$build" ]] || fail "$2 holds another version"
  [[ "$(info CFBundleIdentifier "$app/Contents/Info.plist")" == org.lumashelf.app ]] || fail "$2 has another bundle identifier"
  [[ "$(info FolioSourceCommit "$app/Contents/Info.plist" 2>/dev/null)" == "$head" ]] ||
    fail "$2 was built from another commit or from uncommitted changes; commit, then run make dmg"
  codesign --verify --deep --strict "$app" || fail "$2 has an invalid signature"
  signature="$(codesign -dvv "$app" 2>&1)"
  [[ "$signature" == *"TeamIdentifier=$team"* ]] || fail "$2 is not signed by team $team"
  [[ "$signature" == *"(runtime)"* ]] || fail "$2 lacks the hardened runtime"
  for binary in MacOS/Folio Helpers/folio "PlugIns/Save to Folio.appex/Contents/MacOS/FolioSafari"; do
    archs="$(lipo -archs "$app/Contents/$binary")" || fail "$2 has no $binary"
    [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$2 $binary is not universal: $archs"
  done
  xcrun stapler validate "$app" >/dev/null || fail "$2 has no stapled notarization ticket"
  spctl --assess --type execute "$app" || fail "Gatekeeper rejects $2"
}

[[ "$(codesign -dvv "$dmg" 2>&1)" == *"TeamIdentifier=$team"* ]] || fail "$dmg is not signed by team $team"
xcrun stapler validate "$dmg" >/dev/null || fail "$dmg has no stapled notarization ticket"
spctl --assess --type open --context context:primary-signature "$dmg" || fail "Gatekeeper rejects $dmg"
mkdir "$work/mount"
hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$work/mount" "$dmg" >/dev/null
mount="$work/mount"
check_app "$mount/Folio.app" "the app in $dmg"
hdiutil detach "$mount" >/dev/null
mount=""
ditto -x -k "$zip" "$work/zip"
check_app "$work/zip/Folio.app" "the app in $zip"
print "Release check passed: Folio $version (build $build), notarized and stapled"
