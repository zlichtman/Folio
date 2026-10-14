#!/bin/zsh
# Opens the installed Folio, or builds this checkout when needed and opens the staged build.
# FOLIO_FROM_SOURCE=1 always runs the checkout.
set -euo pipefail
root="${0:A:h}"
if [[ "${FOLIO_FROM_SOURCE:-0}" != 1 ]]; then
  for installed in /Applications/Folio.app ~/Applications/Folio.app; do
    [[ -d "$installed" ]] && { open "$installed"; exit 0 }
  done
fi
# build-app.sh stages the signed app outside iCloud Drive and never unpacks it into the checkout,
# so there is exactly one development copy for Spotlight and Launch Services to find.
cache="${FOLIO_BUILD_CACHE:-${LUMASHELF_BUILD_CACHE:-/private/tmp/folio-build}}"
app="$cache/stage/Folio.app"
binary="$app/Contents/MacOS/Folio"
if [[ ! -x "$binary" || -n "$(find "$root/Sources" "$root/Extensions" "$root/Design" "$root/Info.plist" "$root/Package.swift" -newer "$binary" -print -quit)" ]]; then
  FOLIO_BUILD_CACHE="$cache" FOLIO_ALLOW_ADHOC="${FOLIO_ALLOW_ADHOC:-1}" "$root/scripts/build-app.sh"
fi
codesign --verify --deep --strict "$app"
open "$app"
