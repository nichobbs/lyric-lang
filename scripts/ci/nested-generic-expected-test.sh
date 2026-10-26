#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# nested-generic-expected-test.sh — cross-package regression test: a generic
# call passed to another generic (`keyed("k", paragraph("p"))`) takes its
# type arguments from the outer call's expected type, so the view it builds
# is a `View[Msg]`, not a `View[Object]`.  The mono-level half is in
# mono_self_test.l; this runs the imported case, which `lyric test <file>`
# cannot build.  The JVM erases generics, so there the miscompile never
# failed at run time and this only guards against regressions; dotnet and
# native (whose codegen infers type arguments itself) fail without the fix.
#
#   scripts/ci/nested-generic-expected-test.sh <lyric-binary> dotnet|jvm|native
#
# dotnet/jvm run the fixture's `[project.tests]` suite; native has no manifest
# test runner, so it builds the fixture's `NestedMain` package and runs it
# (needs $LYRIC_RT_PATH, as for every other native build).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${1:?usage: nested-generic-expected-test.sh <lyric-binary> dotnet|jvm|native}"
target="${2:?usage: nested-generic-expected-test.sh <lyric-binary> dotnet|jvm|native}"
manifest="lyric-compiler/fixtures/nested_generic_expected/lyric.toml"

case "$target" in
  dotnet|jvm)
    "$lyric_bin" test --manifest "$manifest" --target "$target"
    ;;
  native)
    out="$(mktemp -d)/nested-generic-expected"
    "$lyric_bin" build --manifest "$manifest" --target native -o "$out"
    got="$("$out")"
    if [ "$got" != "nested-generic-expected: ok" ]; then
      echo "::error::native nested-generic-expected: unexpected output '$got'" >&2
      exit 1
    fi
    ;;
  *)
    echo "nested-generic-expected-test: target must be dotnet, jvm or native, got '$target'" >&2
    exit 2
    ;;
esac
echo "nested-generic-expected ($target) passed"
