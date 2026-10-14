#!/bin/zsh
# Builds a universal, signed Folio.app in /private/tmp/folio-build/stage (FOLIO_BUILD_CACHE moves it).
# The unpacked app stays there: dist/ holds only archives, because Spotlight indexes every app bundle
# it finds and dist/ sits in iCloud Drive, which can add FinderInfo that breaks the signature.
# package-release.sh ships the staged copy.
set -euo pipefail
root="${0:A:h:h}"
cache="${FOLIO_BUILD_CACHE:-${LUMASHELF_BUILD_CACHE:-/private/tmp/folio-build}}"
stage="$cache/stage"
app="$stage/Folio.app"
dist="$root/dist"
fail() { print -u2 "build-app: $*"; exit 1 }
cd "$root"

# Recorded in the bundle; check-release.sh refuses artifacts from another commit or uncommitted changes.
commit="$(git rev-parse HEAD 2>/dev/null || print unknown)"
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || commit+=-dirty

identity="${FOLIO_SIGNING_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  # Prefer the release team's identity when the keychain holds several.
  team="${FOLIO_TEAM_ID:-28LJG7MXT3}"
  identities=("${(@f)$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"Developer ID Application:/ { print $2 }')}")
  identity="${${(@M)identities:#*\($team\)}[1]:-$identities[1]}"
fi
if [[ -z "$identity" ]]; then
  [[ "${FOLIO_ALLOW_ADHOC:-0}" == 1 ]] || fail 'No "Developer ID Application" identity in the keychain. Set FOLIO_ALLOW_ADHOC=1 for a local, ad-hoc signed build.'
  print -u2 ''
  print -u2 '************************************************************'
  print -u2 '*  WARNING: ad-hoc signature. This build is for this Mac   *'
  print -u2 '*  only. It cannot be notarized or published.              *'
  print -u2 '************************************************************'
  print -u2 ''
fi

export CLANG_MODULE_CACHE_PATH="$cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$cache/modules"
swiftpm=(swift build -c release -debug-info-format none --disable-sandbox --cache-path "$cache/swiftpm"
  --scratch-path "$cache/release" --arch arm64 --arch x86_64)
"${swiftpm[@]}"
bin="$("${swiftpm[@]}" --show-bin-path)"
for product in Folio shelf-bench folio-tool; do
  archs="$(lipo -archs "$bin/$product")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || fail "$product is not universal: $archs"
done

rm -rf "$stage"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$dist"
cp "$root/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :FolioSourceCommit string $commit" "$app/Contents/Info.plist"
print -n 'APPL????' > "$app/Contents/PkgInfo"
if [[ "${FOLIO_CURRENT_SDK:-1}" == 1 ]]; then
  # SwiftPM's default build system records the deployment target as the SDK version, so AppKit
  # would keep its pre-macOS 26 appearance. Record the real SDK so controls match MacSpaces.
  vtool -set-build-version macos "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$root/Info.plist")" \
    "$(xcrun --sdk macosx --show-sdk-version)" -replace -output "$app/Contents/MacOS/Folio" "$bin/Folio"
else
  cp "$bin/Folio" "$app/Contents/MacOS/Folio"
fi
swift "$root/scripts/generate-icon.swift" "$stage/Folio.iconset" "$root/Design/folio-app-icon.png"
iconutil -c icns "$stage/Folio.iconset" -o "$app/Contents/Resources/Folio.icns"
rm -rf "$stage/Folio.iconset"

# Browser extensions: Extensions/shared plus each browser's manifest, zipped by build-extensions.sh.
# They ship inside the app so it can offer them without a download; copies land in dist/.
"$root/scripts/build-extensions.sh" "$stage"
mkdir -p "$app/Contents/Resources/Extensions"
for browser in firefox chrome; do
  cp "$stage/folio-$browser.zip" "$app/Contents/Resources/Extensions/folio-$browser.zip"
  cp "$stage/folio-$browser.zip" "$dist/folio-$browser.zip"
done

# Safari's copy of the extension lives inside the app as an app extension.
"$root/scripts/build-safari-extension.sh" "$app" "$stage"
appex="$app/Contents/PlugIns/Save to Folio.appex"

# The folio command and MCP server, and the Safari extension, signed before the app that contains them.
mkdir -p "$app/Contents/Helpers"
cp "$bin/folio-tool" "$app/Contents/Helpers/folio"
xattr -cr "$app"
if [[ -n "$identity" ]]; then
  codesign --force --options runtime --timestamp --entitlements "$root/Extensions/Safari/FolioSafari.entitlements" --sign "$identity" "$appex"
  codesign --force --options runtime --timestamp --sign "$identity" "$app/Contents/Helpers/folio"
  codesign --force --options runtime --timestamp --entitlements "$root/Folio.entitlements" --sign "$identity" "$app"
else
  codesign --force --options runtime --timestamp=none --entitlements "$root/Extensions/Safari/FolioSafari.entitlements" --sign - "$appex"
  codesign --force --options runtime --timestamp=none --sign - "$app/Contents/Helpers/folio"
  codesign --force --options runtime --timestamp=none --entitlements "$root/Folio.entitlements" --sign - "$app"
fi
codesign --verify --deep --strict --verbose=2 "$app"

cp "$bin/shelf-bench" "$stage/shelf-bench"
rm -f "$dist"/Folio-macOS*.zip(N)
ditto -c -k --norsrc --noextattr --keepParent "$app" "$dist/Folio-macOS.zip"
# Earlier builds left an unpacked app, loose tools and extension folders here.
rm -rf "$dist/Folio.app" "$dist/extensions" "$dist/shelf-bench" "$dist/Folio-source.zip" "$dist/SHA256SUMS"
print "Built $app (${identity:-ad-hoc})"
print "Archived to $dist/Folio-macOS.zip; extensions in $dist/folio-firefox.zip and $dist/folio-chrome.zip"
print "Unpacked extensions for development: $stage/extensions"
