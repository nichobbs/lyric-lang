#!/usr/bin/env bash
# stage-selfhosted-stdlib.sh — deploy the stdlib the toolchain links against.
#
# Post-collapse (D111) the stdlib is ONE `Lyric.Stdlib.dll` bundle carrying every
# package, so a single deployed assembly satisfies all `[Lyric.Stdlib]` references.
# The HTTP/async surface (Std.Http, Std.HttpServer, Std.Rest, Std.Task, Std.HttpHost)
# is now included in the bundle (#4030).
#
# This deploys, into each target lib dir:
#   1. Lyric.Stdlib.dll — the single full bundle (lyric.full.toml)
#
# Usage: stage-selfhosted-stdlib.sh <lyric-binary> <lib-dir> [<lib-dir> ...]
set -euo pipefail

LYRIC_BIN="${1:?usage: stage-selfhosted-stdlib.sh <lyric-binary> <lib-dir>...}"
shift
LIB_DIRS=("$@")
if [[ ${#LIB_DIRS[@]} -eq 0 ]]; then
  echo "stage-selfhosted-stdlib: no target lib dirs given" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/lyric-stdlib/lyric.full.toml"

emit_dir="$(mktemp -d)"
trap 'rm -rf "$emit_dir"' EXIT

# Build the single full stdlib bundle.
bundle="$emit_dir/Lyric.Stdlib.dll"
if ! "$LYRIC_BIN" build --manifest "$MANIFEST" -o "$bundle" \
       --target dotnet --no-restore 2>&1; then
  echo "stage-selfhosted-stdlib: building the full stdlib bundle failed (see above)." >&2
  exit 1
fi
[[ -f "$bundle" ]] || { echo "stage-selfhosted-stdlib: bundle not produced at $bundle" >&2; exit 1; }

# Deploy the bundle to every target lib dir.
staged=0
for dir in "${LIB_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  cp "$bundle" "$dir/Lyric.Stdlib.dll"
  staged=$((staged + 1))
done

echo "stage-selfhosted-stdlib: deployed Lyric.Stdlib.dll into $staged lib dir(s)"
