#!/bin/zsh
# Builds the branded drag-to-Applications disk image from an already signed (and, for release,
# stapled) app. Signing and notarizing the image stay in the release script. MacSpaces, Tape and
# Folio ship identical copies of this script, dmg-layout.swift and render-dmg-background.swift.
set -euo pipefail
here="${0:A:h}"
if [[ $# != 3 || "$1" != /* || "$2" != /* ]]; then
  print -u2 "Usage: $0 /absolute/App.app /absolute/output.dmg 'volume name'"; exit 2
fi
app="$1"; output="$2"; volume="$3"
[[ -d "$app/Contents" && ! -e "$output" ]] || { print -u2 'The app is missing or the output already exists.'; exit 2 }
codesign --verify --deep --strict "$app"
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$app/Contents/Info.plist" }
version="$(info CFBundleShortVersionString)"
minimum="$(info LSMinimumSystemVersion)"
archs="$(lipo -archs "$app/Contents/MacOS/$(info CFBundleExecutable)")"
icon="$(info CFBundleIconFile 2>/dev/null)" || icon=AppIcon
icon="$app/Contents/Resources/${icon%.icns}.icns"
work="$(mktemp -d /private/tmp/app-dmg.XXXXXX)"
mount=""
complete=0
cleanup() {
  [[ -z "$mount" ]] || hdiutil detach "$mount" -force >/dev/null 2>&1 || true
  rm -rf "$work"
  [[ "$complete" == 1 ]] || rm -f "$output"
}
trap cleanup EXIT
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$work/clang}"

# The art follows the app's name: folio, tape or macspaces.
swift "$here/render-dmg-background.swift" "${${app:t:r}:l}" "$work/background.tiff" "$version" "$minimum" "$archs"
megabytes=$(( $(du -sk "$app" | cut -f1) / 1024 + 20 ))
hdiutil create -quiet -size "${megabytes}m" -fs HFS+ -volname "$volume" "$work/rw.dmg"
mount="$(hdiutil attach -nobrowse -noautoopen -noverify -readwrite "$work/rw.dmg" | awk -F'\t' '/Apple_HFS/ { print $NF }')"
[[ -d "$mount" ]] || { print -u2 "Could not mount $work/rw.dmg"; exit 1 }
ditto --norsrc --noextattr "$app" "$mount/${app:t}"
codesign --verify --deep --strict "$mount/${app:t}"
ln -s /Applications "$mount/Applications"
cp "$work/background.tiff" "$mount/.background.tiff"
if [[ -f "$icon" ]]; then
  cp "$icon" "$mount/.VolumeIcon.icns"
  # The volume root's Finder flags: kHasCustomIcon, so the mounted image shows the app's icon.
  xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$mount"
fi
swift "$here/dmg-layout.swift" "$mount" "${app:t}"
rm -rf "$mount/.fseventsd" "$mount/.Trashes" "$mount/.Spotlight-V100"
# Spotlight or fseventsd can hold a fresh volume for a moment.
for attempt in 1 2 3 4 5; do
  hdiutil detach "$mount" >/dev/null 2>&1 && break
  (( attempt < 5 )) || { print -u2 "Could not eject $mount"; exit 1 }
  sleep 2
done
mount=""
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$output"
hdiutil verify -quiet "$output"
complete=1
