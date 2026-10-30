#!/usr/bin/env bash
# reject-corpus.sh: the compile-fail corpus (docs/70 §11).
#
# Each directory under lyric-compiler/lyric/testdata/reject/ is a project that
# must NOT compile.  Its `expect` file lists, one per line, the diagnostic codes
# the build must report.  Every case is checked on every target `lyric check`
# supports, and a case passes only when the check fails AND reports every
# expected code on each target, so a program accepted on one target and
# rejected on another fails the corpus.
#
# Native is not covered: `lyric check` supports dotnet and the JVM only.  Native
# cases join when the docs/70 phase 2 resolver is shared by every target
# (#8612).
#
# Usage: scripts/ci/reject-corpus.sh [path/to/lyric] [case-name ...]
# The binary defaults to the AOT build for $BUILD_CONFIG when that is set (CI),
# else ./bin/lyric.
set -euo pipefail

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

corpus="$repo/lyric-compiler/lyric/testdata/reject"
targets=(dotnet jvm)

cases=("$@")
if [ ${#cases[@]} -eq 0 ]; then
  for d in "$corpus"/*/; do
    cases+=("$(basename "$d")")
  done
fi

failed=0
for c in "${cases[@]}"; do
  src="$corpus/$c"
  if [ ! -f "$src/expect" ] || [ ! -f "$src/lyric.toml" ]; then
    echo "::error::reject case '$c' needs lyric.toml and expect"
    failed=1
    continue
  fi
  for t in "${targets[@]}"; do
    work="$(mktemp -d)"
    cp -R "$src/." "$work/"
    set +e
    out="$("$lyric_bin" check --manifest "$work/lyric.toml" --target "$t" 2>&1)"
    rc=$?
    set -e
    rm -rf "$work"
    if [ $rc -eq 0 ]; then
      echo "::error::reject case '$c' ($t) compiled; expected $(tr '\n' ' ' < "$src/expect")"
      echo "$out" | sed 's/^/    /'
      failed=1
      continue
    fi
    missing=""
    while IFS= read -r code; do
      [ -z "$code" ] && continue
      if ! grep -qw -- "$code" <<< "$out"; then
        missing="$missing $code"
      fi
    done < "$src/expect"
    if [ -n "$missing" ]; then
      echo "::error::reject case '$c' ($t) failed without reporting:$missing"
      echo "$out" | sed 's/^/    /'
      failed=1
    else
      echo "ok   $c ($t)"
    fi
  done
done

exit $failed
