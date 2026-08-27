#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-foreign-result-accessor.sh — #6630 / #6710 regressions on the
# reserved `Std.Core.Result[T, E]` / `Option[T]` accessor sugar
# (`.isOk`/`.isErr`/`.value`/`.error`/`.isSome`/`.isNone`).
#
# Three fixtures, all compile-time type-checker rejections (not a
# runtime `Bug` a compiled program could catch, so asserted as `lyric
# build` failures — mirrors the ambiguous-primitive-array-overload
# negative test — rather than `@test_module` assertions):
#
#  1. A user-defined 2-type-arg union literally named `Result`, declared
#     OUTSIDE Std.Core: `.isOk` must get a clean T0124 error, not have
#     the accessor sugar (matched by bare short name before #6630)
#     silently mis-lower it against the wrong case classes.
#  2. #6710: the GENUINE `Std.Core.Result[T, E]`, accessed with the
#     OTHER monad's accessor (`.isSome`) — `monadAccessorShapeMismatchDiag`
#     must not claim this "different type declared outside Std.Core"
#     (there isn't one); the message must name the real cause (wrong
#     accessor for this monad) instead.
#  3. #6710's Option-side mirror: the genuine `Std.Core.Option[T]`
#     accessed with `.isOk` (a Result accessor).
#
# The type checker is shared between targets (both `Msil.Bridge` and
# `Jvm.Bridge` call `Lyric.TypeChecker.checkFile`), so one set of
# fixtures covers both — invoke once per target:
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

# ── Fixture 1 (#6630): foreign lookalike Result ─────────────────────────────
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

# ── Fixture 2 (#6710): genuine Std.Core.Result, wrong (Option's) accessor ──
genres="$dir/genuineresult.l"
cat > "$genres" <<'LYRIC'
package GenuineResultWrongAccessor
import Std.Core
func make(): Result[Int, String] {
  Ok(value = 1)
}
func main(): Int {
  val r = make()
  if r.isSome {
    println("ok")
  }
  0
}
LYRIC

if "$lyric_bin" build --target "$target" "$genres" -o "$dir/genuineresult.$out_ext" > "$dir/genuineresult.out" 2>&1; then
  echo "::error::a genuine Std.Core.Result's .isSome (Option's accessor) compiled on --target $target — #6710 wrong-accessor-for-this-monad check did not fire" >&2
  cat "$dir/genuineresult.out"
  exit 1
fi
if ! grep -q "T0124" "$dir/genuineresult.out"; then
  echo "::error::genuine Result.isSome failed without the expected T0124 diagnostic on --target $target" >&2
  cat "$dir/genuineresult.out"
  exit 1
fi
if grep -qi "declared outside Std.Core" "$dir/genuineresult.out"; then
  echo "::error::#6710 regression: genuine Std.Core.Result's .isSome falsely claims a foreign 'declared outside Std.Core' type on --target $target" >&2
  cat "$dir/genuineresult.out"
  exit 1
fi
echo "OK: a genuine Std.Core.Result's .isSome (Option's accessor) gets an accurate T0124 error on --target $target, no false foreign-type claim."

# ── Fixture 3 (#6710): genuine Std.Core.Option, wrong (Result's) accessor ──
genopt="$dir/genuineoption.l"
cat > "$genopt" <<'LYRIC'
package GenuineOptionWrongAccessor
import Std.Core
func make(): Option[Int] {
  Some(value = 1)
}
func main(): Int {
  val o = make()
  if o.isOk {
    println("ok")
  }
  0
}
LYRIC

if "$lyric_bin" build --target "$target" "$genopt" -o "$dir/genuineoption.$out_ext" > "$dir/genuineoption.out" 2>&1; then
  echo "::error::a genuine Std.Core.Option's .isOk (Result's accessor) compiled on --target $target — #6710 wrong-accessor-for-this-monad check did not fire" >&2
  cat "$dir/genuineoption.out"
  exit 1
fi
if ! grep -q "T0124" "$dir/genuineoption.out"; then
  echo "::error::genuine Option.isOk failed without the expected T0124 diagnostic on --target $target" >&2
  cat "$dir/genuineoption.out"
  exit 1
fi
if grep -qi "declared outside Std.Core" "$dir/genuineoption.out"; then
  echo "::error::#6710 regression: genuine Std.Core.Option's .isOk falsely claims a foreign 'declared outside Std.Core' type on --target $target" >&2
  cat "$dir/genuineoption.out"
  exit 1
fi
echo "OK: a genuine Std.Core.Option's .isOk (Result's accessor) gets an accurate T0124 error on --target $target, no false foreign-type claim."
