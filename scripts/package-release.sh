#!/bin/zsh
# Builds, signs, notarizes and staples Folio.app and Folio.dmg, verifies them, then writes
# dist/Folio.dmg, dist/Folio-<version>.zip and dist/SHA256SUMS.txt, which also covers the browser
# extension zips build-app.sh leaves in dist/. The unpacked app never leaves /private/tmp.
# FOLIO_NOTARIZE=0 skips Apple's notary service for a local dry run; that output cannot be published.
set -euo pipefail
root="${0:A:h:h}"
cache="${FOLIO_BUILD_CACHE:-${LUMASHELF_BUILD_CACHE:-/private/tmp/folio-build}}"
notarize="${FOLIO_NOTARIZE:-1}"
profile="${FOLIO_NOTARY_PROFILE:-MacSpaces}"
dist="$root/dist"
info() { /usr/libexec/PlistBuddy -c "Print :$1" "${2:-$root/Info.plist}" }
fail() { print -u2 "package-release: $*"; exit 1 }
version="$(info CFBundleShortVersionString)"
build="$(info CFBundleVersion)"
work="$(mktemp -d /private/tmp/folio-release.XXXXXX)"
mount=""
cleanup() {
  [[ -z "$mount" ]] || hdiutil detach "$mount" -force >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

if [[ "$notarize" == 1 ]]; then
  # Fail before the slow notary rounds on anything check-release.sh would refuse later.
  "$root/scripts/check-release.sh" --metadata
  [[ -z "$(git -C "$root" status --porcelain)" ]] || fail 'Commit your changes first: a release must match a commit.'
fi
FOLIO_BUILD_CACHE="$cache" "$root/scripts/build-app.sh"
app="$work/Folio.app"
ditto "$cache/stage/Folio.app" "$app"
identity="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p' | head -1)"
[[ "$notarize" != 1 || -n "$identity" ]] || fail 'Notarization needs a Developer ID Application signature.'

submit() {
  local started=$SECONDS result="$work/notary-${1:t}.json" id state
  xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --timeout 60m --output-format json > "$result" || true
  id="$(plutil -extract id raw -o - "$result" 2>/dev/null || true)"
  state="$(plutil -extract status raw -o - "$result" 2>/dev/null || true)"
  if [[ "$state" != Accepted ]]; then
    [[ -z "$id" ]] || xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    fail "Notarizing ${1:t} ended with ${state:-no result}: $(<"$result")"
  fi
  print "Notarized ${1:t} in $((SECONDS - started)) s (submission $id)"
}

# Two rounds, app then disk image, so both carry a ticket and pass Gatekeeper offline.
notarization="Not submitted (FOLIO_NOTARIZE=0)"
if [[ "$notarize" == 1 ]]; then
  ditto -c -k --keepParent "$app" "$work/Folio-notary.zip"
  submit "$work/Folio-notary.zip"
  xcrun stapler staple "$app"
  xcrun stapler validate "$app"
fi

dmg="$work/Folio.dmg"
"$root/scripts/make-dmg.sh" "$app" "$dmg" "Folio $version"
if [[ -n "$identity" ]]; then
  codesign --force --timestamp --sign "$identity" "$dmg"
else
  codesign --force --timestamp=none --sign - "$dmg"
fi
codesign --verify --strict --verbose=2 "$dmg"
if [[ "$notarize" == 1 ]]; then
  submit "$dmg"
  xcrun stapler staple "$dmg"
  xcrun stapler validate "$dmg"
  notarization="Accepted and stapled (app and disk image)"
fi

# Check the exact payload people download.
mkdir "$work/mount"
hdiutil attach -nobrowse -noautoopen -readonly -mountpoint "$work/mount" "$dmg" >/dev/null
mount="$work/mount"
mounted="$mount/Folio.app"
codesign --verify --deep --strict --verbose=2 "$mounted"
archs="$(lipo -archs "$mounted/Contents/MacOS/Folio")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "The packaged app is not universal: $archs"
[[ "$(info CFBundleShortVersionString "$mounted/Contents/Info.plist")" == "$version" &&
   "$(info CFBundleVersion "$mounted/Contents/Info.plist")" == "$build" ]] || fail 'The packaged app has another version'
gatekeeper=0
assessment="$(spctl --assess --type execute --verbose=2 "$mounted" 2>&1)" || gatekeeper=1
assessment+=$'\n'"$(spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg" 2>&1)" || gatekeeper=1
if [[ "$notarize" == 1 ]]; then
  xcrun stapler validate "$mounted"
  [[ "$gatekeeper" == 0 ]] || fail "Gatekeeper rejected the release: $assessment"
fi
hdiutil detach "$mount" >/dev/null
mount=""

zip="$work/Folio-$version.zip"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$zip"
mkdir -p "$dist"
rm -f "$dist/Folio.dmg" "$dist/SHA256SUMS.txt" "$dist"/Folio-<->.<->.<->.zip(N)
mv "$dmg" "$zip" "$dist/"
extensions=(folio-firefox.zip folio-chrome.zip)
for file in $extensions; do [[ -f "$dist/$file" ]] || fail "build-app.sh did not produce dist/$file"; done
(cd "$dist" && shasum -a 256 Folio.dmg "Folio-$version.zip" $extensions > SHA256SUMS.txt)

print "\nFolio $version (build $build)"
print "Signed with: ${identity:-ad-hoc}"
print "Notarization: $notarization"
print "Gatekeeper:\n$assessment"
print "Artifacts:"
for file in Folio.dmg "Folio-$version.zip" $extensions; do
  print "  dist/$file  $(( $(stat -f %z "$dist/$file") / 1024 )) KB  $(grep -F " $file" "$dist/SHA256SUMS.txt" | cut -d' ' -f1)"
done
[[ "$notarize" == 1 ]] || print -u2 '\nThis is a dry run: notarize with make dmg before publishing.'
