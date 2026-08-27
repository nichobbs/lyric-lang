#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-foreign-result-accessor.sh — #6630 regression: a user-defined
# 2-type-arg union named `Result` (declared OUTSIDE Std.Core) must get a
# clean T0124 type error on `.isOk`, not have the reserved
# Std.Core.Result accessor sugar (monadAccessorType/
# lowerBuiltinMonadAccessorMsil, matched by bare short name before this
# fix) silently mis-lower it against the wrong case classes. This is a
# compile-time type-checker rejection, not a runtime `Bug` a compiled
# program could catch, so it is asserted as a `lyric build` failure
# (mirrors the ambiguous-primitive-array-overload negative test) rather
# than a `@test_module` assertion.
#
# The type checker is shared between targets (both `Msil.Bridge` and
# `Jvm.Bridge` call `Lyric.TypeChecker.checkFile`), so one fixture covers
# both — invoke once per target:
#
#   bash scripts/ci/check-foreign-result-accessor.sh dotnet
#   bash scripts/ci/check-foreign-result-accessor.sh jvm
#
# Extracted out of ci.yml (originally two near-identical inline `run:`
# blocks) to keep the workflow file under its size ceiling — see
# scripts/ci/self-test.sh's header for the full story on why that matters.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

if [[ $# -ne 1 || ( "$1" != "dotnet" && "$1" != "jvm" ) ]]; then
  echo "::error::check-foreign-result-accessor.sh: usage: check-foreign-result-accessor.sh <dotnet|jvm>" >&2
  exit 2
fi
target="$1"

if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping #6630 foreign-Result negative test (--target $target)" >&2
  exit 1
fi

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping #6630 foreign-Result negative test (--target $target)" >&2
  exit 1
fi

out_ext="dll"
if [[ "$target" == "jvm" ]]; then
  out_ext="jar"
fi

dir="$(mktemp -d)"
neg="$dir/foreignresult.l"
cat > "$neg" <<'LYRIC'
package ForeignResult
union Result[T, E] {
  case Ok(value: T)
  case Err(error: E)
}
func make(): Result[Int, String] {
  Ok(value = 1)
}
func main(): Int {
  val r = make()
  if r.isOk {
    println("ok")
  }
  0
}
LYRIC

if "$lyric_bin" build --target "$target" "$neg" -o "$dir/foreignresult.$out_ext" > "$dir/foreignresult.out" 2>&1; then
  echo "::error::a foreign (non-Std.Core) Result[T, E] union's .isOk compiled on --target $target — #6630 package-path qualification did not fire" >&2
  cat "$dir/foreignresult.out"
  exit 1
fi

if ! grep -q "T0124" "$dir/foreignresult.out"; then
  echo "::error::foreign Result.isOk failed without the expected T0124 diagnostic on --target $target (may be a different, unrelated failure, or a silent miscompile)" >&2
  cat "$dir/foreignresult.out"
  exit 1
fi

echo "OK: a foreign (non-Std.Core) Result[T, E] union's .isOk gets a clean T0124 type error on --target $target, not a miscompile."
