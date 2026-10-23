#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# builtin-name-override-test.sh — cross-package regression test for #7508
# (run-time half, #7675): a package that declares `newList`/`mapGet` and is
# imported by another package must win over the builtin collection intrinsic
# of the same bare name, on every backend.  The same-package case is
# conversion_name_resolution_self_test.l; this covers the imported case, which
# `lyric test <file>` cannot build.
#
#   scripts/ci/builtin-name-override-test.sh <lyric-binary> dotnet|jvm|native
#
# dotnet/jvm run the fixture's `[project.tests]` suite; native has no manifest
# test runner, so it builds the fixture's `OverrideMain` package and runs it
# (needs $LYRIC_RT_PATH, as for every other native build).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${1:?usage: builtin-name-override-test.sh <lyric-binary> dotnet|jvm|native}"
target="${2:?usage: builtin-name-override-test.sh <lyric-binary> dotnet|jvm|native}"
manifest="lyric-compiler/fixtures/builtin_name_override/lyric.toml"

case "$target" in
  dotnet|jvm)
    "$lyric_bin" test --manifest "$manifest" --target "$target"
    ;;
  native)
    out="$(mktemp -d)/builtin-name-override"
    "$lyric_bin" build --manifest "$manifest" --target native -o "$out"
    got="$("$out")"
    if [ "$got" != "builtin-name-override: ok" ]; then
      echo "::error::native builtin-name-override: unexpected output '$got'" >&2
      exit 1
    fi
    ;;
  *)
    echo "builtin-name-override-test: target must be dotnet, jvm or native, got '$target'" >&2
    exit 2
    ;;
esac
echo "builtin-name-override ($target) passed"
