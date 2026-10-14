#!/bin/zsh
# Builds the Safari web extension: Extensions/shared plus Extensions/Safari/manifest.json, inside an app extension
# (Save to Folio.appex) with a small native handler, universal, placed in <app>/Contents/PlugIns. Safari finds it
# once Folio has been opened, and it's switched on in Safari ▸ Settings ▸ Extensions.
# Usage: build-safari-extension.sh <Folio.app> <scratch folder>
set -euo pipefail
root="${0:A:h:h}"; app="${1:?app}"; work="${2:?scratch}"
appex="$app/Contents/PlugIns/Save to Folio.appex"
rm -rf "$appex" "$work/safari"; mkdir -p "$appex/Contents/MacOS" "$appex/Contents/Resources" "$work/safari"
plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$root/Info.plist"; }
sed -e "s/VERSION/$(plist CFBundleShortVersionString)/" -e "s/BUILD/$(plist CFBundleVersion)/" \
    -e "s/COPYRIGHT/$(plist NSHumanReadableCopyright | sed 's/[&/]/\\&/g')/" "$root/Extensions/Safari/Info.plist" > "$appex/Contents/Info.plist"
min="$(plist LSMinimumSystemVersion)"
for arch in arm64 x86_64; do
  xcrun swiftc -O -parse-as-library -application-extension -module-name FolioSafari -target "$arch-apple-macos$min" \
    -Xlinker -e -Xlinker _NSExtensionMain -framework SafariServices \
    "$root/Extensions/Safari/SafariWebExtensionHandler.swift" -o "$work/safari/FolioSafari-$arch"
done
lipo -create "$work/safari/FolioSafari-arm64" "$work/safari/FolioSafari-x86_64" -output "$appex/Contents/MacOS/FolioSafari"
cp -R "$root/Extensions/shared/." "$appex/Contents/Resources/"
# Safari shows the extension's version in its settings: keep it the app's.
sed -e "s/\"version\": \"[^\"]*\"/\"version\": \"$(plist CFBundleShortVersionString)\"/" "$root/Extensions/Safari/manifest.json" > "$appex/Contents/Resources/manifest.json"
find "$appex" -name '.*' -type f -delete
print -n 'XPC!????' > "$appex/Contents/PkgInfo"
print "Built $appex"
