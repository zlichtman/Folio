#!/bin/zsh
# Assembles the Firefox and Chrome extensions from Extensions/shared plus each browser's manifest.
# Output in the given folder (default: the build stage in /private/tmp): extensions/<browser>/ (load unpacked)
# and folio-<browser>.zip. build-app.sh copies only the zips to dist/.
set -euo pipefail
task_root="${0:A:h:h}"
task_out="${1:-${FOLIO_BUILD_CACHE:-/private/tmp/folio-build}/stage}"
mkdir -p "$task_out"
task_out="${task_out:A}"
for browser in firefox chrome; do
  task_dir="$task_out/extensions/$browser"
  rm -rf "$task_dir" "$task_out/folio-$browser.zip"
  mkdir -p "$task_dir"
  cp -R "$task_root/Extensions/shared/." "$task_dir/"
  cp "$task_root/Extensions/${(C)browser}/manifest.json" "$task_dir/manifest.json"
  find "$task_dir" -name '.*' -type f -delete
  (cd "$task_dir" && zip -q -r -X "$task_out/folio-$browser.zip" .)
done
print "Built $task_out/folio-firefox.zip and $task_out/folio-chrome.zip"
