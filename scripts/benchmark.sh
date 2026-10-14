#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_bench="${1:-/private/tmp/folio-bench}"
task_stage="${FOLIO_BUILD_CACHE:-/private/tmp/folio-build}/stage"  # make app stages these
mkdir -p "$task_bench"
"$task_stage/shelf-bench" generate --folder "$task_bench/fixtures" --count 10000
"$task_stage/shelf-bench" run --folder "$task_bench/fixtures" --library "$task_bench/library" --output "$task_bench/core.json"
"$task_stage/Folio.app/Contents/MacOS/Folio" --library "$task_bench/library" --benchmark-json "$task_bench/grid.json" --quit-after-benchmark
print "Reports: $task_bench/core.json and $task_bench/grid.json"
