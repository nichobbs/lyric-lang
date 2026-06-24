#!/usr/bin/env bash
# stage-selfhosted-stdlib.sh — deploy the stdlib the toolchain links against.
#
# Post-collapse (D111) the stdlib is ONE `Lyric.Stdlib.dll` bundle carrying every
# package, so a single deployed assembly satisfies the collapsed `[Lyric.Stdlib]`
# references.  The exception is the HTTP/async surface (Std.Http, Std.HttpServer,
# Std.Rest, Std.Task, Std.HttpHost): the self-hosted emitter cannot yet emit those
# async-`Task`/`Result`-heavy packages into the single `output = "single"` bundle
# (Phase A undercounts a cross-package `match await`, and a bundled HttpServer
# emits invalid IL — #4030).  They build and run correctly PER-PACKAGE, so this
# script ships them as `Lyric.Stdlib.<X>.dll` alongside the bundle, and
# `stdlibAssemblyName` keeps their references on the per-package identity.
#
# This deploys, into each target lib dir:
#   1. Lyric.Stdlib.dll                — the single full bundle (lyric.full.toml)
#   2. Lyric.Stdlib.{Http,HttpServer,Rest,Task,HttpHost,*Host}.dll — per-package
#
# The F#-emitted per-package DLLs the mint compiler closure links at run time
# (`Lyric.Stdlib.Core.dll`, …, non-suffixed identities) are left in place.
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

# 1. The single full stdlib bundle.
bundle="$emit_dir/Lyric.Stdlib.dll"
if ! "$LYRIC_BIN" build --manifest "$MANIFEST" -o "$bundle" \
       --target dotnet --no-restore 2>&1; then
  echo "stage-selfhosted-stdlib: building the full stdlib bundle failed (see above)." >&2
  exit 1
fi
[[ -f "$bundle" ]] || { echo "stage-selfhosted-stdlib: bundle not produced at $bundle" >&2; exit 1; }

# 2. The per-package HTTP/async surface (not bundleable yet, #4030).  Emit the
#    whole import closure of a driver importing the public HTTP packages; the
#    transitive host packages (Std.Task, Std.HttpHost) land in the same emit.
http_driver="$emit_dir/http_driver.l"
{
  echo "package SelfHostedHttpStage"
  echo "import Std.Http"
  echo "import Std.HttpServer"
  echo "import Std.Rest"
  echo "func main(): Unit { }"
} > "$http_driver"
http_out="$emit_dir/http_out"
if ! "$LYRIC_BIN" --internal-perpackage-build "$http_driver" "$http_out" --target dotnet 2>&1; then
  echo "stage-selfhosted-stdlib: per-package HTTP emit failed (see above)." >&2
  exit 1
fi
# The HTTP packages and their host sub-packages (Task, HttpHost) — fail loudly if
# a curated HTTP DLL is missing after a successful emit.
http_pkgs=(Http HttpServer Rest Task HttpHost)
http_dlls=()
for p in "${http_pkgs[@]}"; do
  dll="$http_out/Lyric.Stdlib.$p.dll"
  [[ -f "$dll" ]] || { echo "stage-selfhosted-stdlib: expected $dll missing after HTTP emit (#4030)." >&2; exit 1; }
  http_dlls+=("$dll")
done

# 3. Deploy.  The bundle overwrites the smoke `Lyric.Stdlib.dll`; the HTTP
#    per-package DLLs are copied (clobbering older copies) alongside it.
staged=0
for dir in "${LIB_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  cp "$bundle" "$dir/Lyric.Stdlib.dll"
  for dll in "${http_dlls[@]}"; do
    cp "$dll" "$dir/"
  done
  staged=$((staged + 1))
done

echo "stage-selfhosted-stdlib: deployed Lyric.Stdlib.dll + ${#http_dlls[@]} per-package HTTP DLLs into $staged lib dir(s)"
