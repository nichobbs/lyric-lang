#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# nested-generic-expected-test.sh — cross-package regression test: a generic
# call passed to another generic (`keyed("k", paragraph("p"))`) takes its
# type arguments from the outer call's expected type, so the view it builds
# is a `View[Msg]`, not a `View[Object]`.  The mono-level half is in
# mono_self_test.l; this runs the imported case, which `lyric test <file>`
# cannot build.
#
#   scripts/ci/nested-generic-expected-test.sh <lyric-binary> dotnet|jvm
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${1:?usage: nested-generic-expected-test.sh <lyric-binary> dotnet|jvm}"
target="${2:?usage: nested-generic-expected-test.sh <lyric-binary> dotnet|jvm}"
manifest="lyric-compiler/fixtures/nested_generic_expected/lyric.toml"

case "$target" in
  dotnet|jvm)
    "$lyric_bin" test --manifest "$manifest" --target "$target"
    ;;
  *)
    echo "nested-generic-expected-test: target must be dotnet or jvm, got '$target'" >&2
    exit 2
    ;;
esac
echo "nested-generic-expected ($target) passed"
