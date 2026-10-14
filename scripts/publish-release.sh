#!/bin/zsh
# Publishes dist/ as the GitHub release v<version> and prints the Homebrew cask to commit.
# Run after make dmg, with the release commit pushed to main and CI passing on it.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
repo=zlichtman/Folio
fail() { print -u2 "publish-release: $*"; exit 1 }
info() { /usr/libexec/PlistBuddy -c "Print :$1" Info.plist }
[[ $# == 1 ]] || { print -u2 "Usage: $0 <version>"; exit 2 }
version="$1"
tag="v$version"
build="$(info CFBundleVersion)"
[[ "$version" == "$(info CFBundleShortVersionString)" ]] || fail "Info.plist is at $(info CFBundleShortVersionString); run scripts/bump-version.sh $version"
[[ -z "$(git status --porcelain)" ]] || fail 'The working tree has changes; publish only a committed snapshot.'
! git rev-parse -q --verify "refs/tags/$tag" >/dev/null || fail "Tag $tag already exists"
"$root/scripts/check-release.sh"

commit="$(git rev-parse HEAD)"
remote_tag="$(git ls-remote --tags origin "refs/tags/$tag")"
[[ -z "$remote_tag" ]] || fail "Tag $tag already exists on origin"
! gh release view "$tag" --repo "$repo" >/dev/null 2>&1 || fail "Release $tag already exists"
main="$(git ls-remote origin refs/heads/main)"
[[ "${main%%[[:space:]]*}" == "$commit" ]] || fail 'Push this commit to main first.'
passed="$(gh run list --repo "$repo" --workflow ci.yml --commit "$commit" --json conclusion --jq '[.[] | select(.conclusion == "success")] | length')"
[[ "$passed" != 0 ]] || fail "CI has not passed on $commit"
# The updater compares this marker, so every published installer needs a larger build.
newest="$(gh api --paginate "repos/$repo/releases" --jq '.[] | select(.draft | not) | .body // ""' |
  tr -d '\r' | sed -n 's/^<!-- folio-build:\([0-9][0-9]*\) -->$/\1/p' | sort -n | tail -1)"
(( build > ${newest:-0} )) || fail "Build $build must exceed the newest published build $newest; run scripts/bump-version.sh"

notes="$(mktemp /private/tmp/folio-notes.XXXXXX)"
trap 'rm -f "$notes"' EXIT
print -r -- "$(<RELEASE_NOTES.md)"$'\n\n'"<!-- folio-build:$build -->" > "$notes"
git tag -a "$tag" -m "Folio $version" "$commit"
git push origin "refs/tags/$tag"
gh release create "$tag" dist/Folio.dmg "dist/Folio-$version.zip" --repo "$repo" --title "Folio $version" \
  --notes-file "$notes" --verify-tag --latest
sha="$(shasum -a 256 dist/Folio.dmg | cut -d' ' -f1)"
digest="$(gh api "repos/$repo/releases/tags/$tag" --jq '.assets[] | select(.name == "Folio.dmg") | .digest')"
[[ "$digest" == "sha256:$sha" ]] || fail "The uploaded Folio.dmg ($digest) differs from dist/Folio.dmg"
print "Published Folio $version (build $build): https://github.com/$repo/releases/tag/$tag"
print "\nCasks/folio.rb for zlichtman/homebrew-tap (run brew style --cask and brew audit --cask --strict before pushing):\n"
sed -e "s/^  version \".*\"$/  version \"$version\"/" -e "s/^  sha256 \".*\"$/  sha256 \"$sha\"/" packaging/folio.rb
