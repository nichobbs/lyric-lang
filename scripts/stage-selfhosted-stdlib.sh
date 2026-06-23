#!/usr/bin/env bash
# stage-selfhosted-stdlib.sh — deploy the single full stdlib bundle.
#
# Post-collapse (D111) every `Std.*` reference resolves to the single
# `Lyric.Stdlib` assembly identity, so one deployed `Lyric.Stdlib.dll` carrying
# every package (built from `lyric-stdlib/lyric.full.toml`, `output = "single"`)
# satisfies all stdlib references — including the packages the F# stage-0 emitter
# never shipped (Std.Sort, Std.Http, Std.Xml, …).  This replaces the previous
# per-package fill-in emit: a user program importing any `Std.*` package now
# links the one bundle rather than a `Lyric.Stdlib.<X>.dll` whose assembly
# identity no longer matches the collapsed references.
#
# The bundle OVERWRITES the smoke-set `Lyric.Stdlib.dll` that `bootstrap.sh`
# stage 1 deposits (the full bundle is a strict superset).  The F#-emitted
# per-package DLLs the mint compiler closure links at run time
# (`Lyric.Stdlib.Core.dll`, …, non-suffixed assembly identities) are left in
# place — they are a different assembly identity and never collide with the
# single `Lyric.Stdlib` bundle.
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

bundle="$emit_dir/Lyric.Stdlib.dll"
if ! "$LYRIC_BIN" build --manifest "$MANIFEST" -o "$bundle" \
       --target dotnet --no-restore 2>&1; then
  echo "stage-selfhosted-stdlib: building the full stdlib bundle failed (see above)." >&2
  exit 1
fi
[[ -f "$bundle" ]] || { echo "stage-selfhosted-stdlib: bundle not produced at $bundle" >&2; exit 1; }

staged=0
for dir in "${LIB_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  cp "$bundle" "$dir/Lyric.Stdlib.dll"   # overwrite the smoke bundle with the full one
  staged=$((staged + 1))
done

echo "stage-selfhosted-stdlib: deployed the single full Lyric.Stdlib.dll bundle into $staged lib dir(s)"
