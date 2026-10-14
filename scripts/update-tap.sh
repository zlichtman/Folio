#!/bin/zsh
# Points the Homebrew cask in zlichtman/homebrew-tap at a published release. Refuses unless the release's
# Folio.dmg downloads and matches dist/Folio.dmg, so the cask never names an installer that isn't there.
# Usage: scripts/update-tap.sh X.Y   (after scripts/publish-release.sh X.Y)
set -euo pipefail
root="${0:A:h:h}"
[[ $# == 1 ]] || { print -u2 "Usage: $0 <version>"; exit 2 }
version="$1"
work="$(mktemp -d /private/tmp/folio-tap.XXXXXX)"
trap 'rm -rf "$work"' EXIT
url="https://github.com/zlichtman/Folio/releases/download/v$version/Folio.dmg"
curl -fsSL "$url" -o "$work/Folio.dmg" || { print -u2 "update-tap: $url isn't downloadable; publish the release first."; exit 1 }
published="$(shasum -a 256 "$work/Folio.dmg" | cut -d' ' -f1)"
local_sha="$(shasum -a 256 "$root/dist/Folio.dmg" | cut -d' ' -f1)"
[[ "$published" == "$local_sha" ]] || { print -u2 "update-tap: the published installer differs from dist/Folio.dmg."; exit 1 }
gh repo clone zlichtman/homebrew-tap "$work/tap" -- -q
sed -i '' "s/^  version \".*\"/  version \"$version\"/; s/^  sha256 \".*\"/  sha256 \"$published\"/" "$work/tap/Casks/folio.rb"
git -C "$work/tap" -c user.name="Zach Lichtman" -c user.email="130262074+zlichtman@users.noreply.github.com" commit -qam "Folio $version

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git -C "$work/tap" push -q origin HEAD
print "Cask folio is at $version ($published)."
