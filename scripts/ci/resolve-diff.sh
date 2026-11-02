#!/usr/bin/env bash
# resolve-diff.sh: the resolver differential census (docs/70 phase 2c, D314).
#
# With LYRIC_RESOLVE_DIFF=1 the type checker answers every bare name lookup
# twice, once through Lyric.Resolve and once through its own scan, and reports
# a difference as an R0001 warning.  Every project in the repository must
# produce none: a difference is either a resolver bug or a rule change that
# needs a census and a migration first (docs/70 §12.2).
#
# Usage: scripts/ci/resolve-diff.sh [path/to/lyric] [manifest ...]
# With no manifests, every lyric.toml under the repository is checked except
# those under hidden directories, testdata/ and node_modules/.  The binary
# defaults to the AOT build for $BUILD_CONFIG when that is set (CI), else
# ./bin/lyric.
set -uo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
if [ -n "${BUILD_CONFIG:-}" ]; then
  default_bin="$repo/bootstrap/src/Lyric.Cli.Aot/bin/$BUILD_CONFIG/net10.0/lyric"
else
  default_bin="$repo/bin/lyric"
fi
lyric_bin="${1:-$default_bin}"
shift || true
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin"
  exit 1
fi

manifests=("$@")
if [ ${#manifests[@]} -eq 0 ]; then
  while IFS= read -r m; do
    manifests+=("$m")
  done < <(cd "$repo" && find . -name lyric.toml \
    -not -path '*/.*' -not -path '*/testdata/*' -not -path '*/node_modules/*' | sort | sed 's|^\./||')
fi

disagreements=0
checked=0
for m in "${manifests[@]}"; do
  path="$m"
  case "$path" in /*) ;; *) path="$repo/$path" ;; esac
  out="$(LYRIC_RESOLVE_DIFF=1 "$lyric_bin" check --manifest "$path" --target dotnet 2>&1)" || true
  checked=$((checked + 1))
  hits="$(printf '%s\n' "$out" | grep 'R0001' || true)"
  if [ -n "$hits" ]; then
    echo "::error::resolver disagrees with the checker in $m"
    printf '%s\n' "$hits"
    disagreements=$((disagreements + 1))
  fi
done

echo "resolve-diff: $checked project(s) checked, $disagreements with disagreements"
[ "$disagreements" -eq 0 ]
