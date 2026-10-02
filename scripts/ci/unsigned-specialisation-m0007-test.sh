#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# unsigned-specialisation-m0007-test.sh — M0007 negative-compile test (#7842,
# #8024).
#
# A generic specialised with `UInt`/`ULong` is type-checked again with its
# type arguments substituted, so its operands can be made unsigned from the
# checker's types.  A specialisation whose substituted body does not
# type-check must fail the build with M0007 rather than compile signed.  The
# path is target-independent (`Lyric.Pipeline.recheckUnsignedSpecs`), so the
# fixture is built for both dotnet and jvm, alongside a clean control.
# `mono_self_test.l` covers the other M0007 path (the declaring package not
# in scope) through the same entry point.
#
# Usage: bash scripts/ci/unsigned-specialisation-m0007-test.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping M0007 negative test"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/m0007_fixture.l" <<'LYR'
package M0007Fixture

import Std.Core

// Generically `x` may be any type, but specialised with `T = UInt` the
// binding is a `String` initialised with a `UInt`.
func asText[T](x: in T): String {
  val s: String = x
  s
}

func main(): Unit {
  println(asText(4000000000u32))
}
LYR

cat > "$work/m0007_control.l" <<'LYR'
package M0007Control

import Std.Core

func shown[T](x: in T): String = "${x}"

func main(): Unit {
  println(shown(4000000000u32))
}
LYR

expected="cannot specialise 'asText__UInt': with its type arguments substituted the body does not type-check (T0060"
for target in dotnet jvm; do
  rc=0
  ( cd "$work" && "$bin_abs" build --target "$target" m0007_fixture.l ) > "$work/fixture_$target.out" 2>&1 || rc=$?
  echo "--- M0007 fixture, --target $target (rc=$rc) ---"; cat "$work/fixture_$target.out"
  if [ "$rc" -eq 0 ]; then
    echo "::error::expected a non-zero exit for a UInt specialisation that does not type-check (--target $target)"
    exit 1
  fi
  grep -q "error\[M0007\]" "$work/fixture_$target.out" || {
    echo "::error::the build failed but did not report M0007 (--target $target)"; exit 1; }
  grep -qF "$expected" "$work/fixture_$target.out" || {
    echo "::error::M0007 did not carry the expected message (--target $target)"; exit 1; }
  rc=0
  ( cd "$work" && "$bin_abs" build --target "$target" m0007_control.l ) > "$work/control_$target.out" 2>&1 || rc=$?
  echo "--- clean control, --target $target (rc=$rc) ---"; cat "$work/control_$target.out"
  if [ "$rc" -ne 0 ]; then
    echo "::error::a UInt specialisation that type-checks failed to build (--target $target)"
    exit 1
  fi
done
echo "M0007 negative test passed on dotnet and jvm"
