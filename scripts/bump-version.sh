#!/bin/zsh
# Advances the build and sets the public version to <major>.<build>, the convention MacSpaces and Tape use.
# Usage: scripts/bump-version.sh [major]   (keeps the current major when omitted)
set -euo pipefail
plist="${0:A:h:h}/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "$1" "$plist" }
current="$(pb 'Print :CFBundleShortVersionString')"
build="$(pb 'Print :CFBundleVersion')"
[[ "$build" == <1-> ]] || { print -u2 "CFBundleVersion must be a positive integer, not $build"; exit 1 }
major="${1:-${current%%.*}}"
[[ "$major" == <1-> ]] || { print -u2 "Usage: $0 [major], for example 1"; exit 2 }
(( major >= ${current%%.*} )) || { print -u2 "Major $major is older than $current"; exit 1 }
# Every installer gets a new build, and the build is the version's second number.
next=$((build + 1))
pb "Set :CFBundleShortVersionString $major.$next"
pb "Set :CFBundleVersion $next"
print "Folio $major.$next"
