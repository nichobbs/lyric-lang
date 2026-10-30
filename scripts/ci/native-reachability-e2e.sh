#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-reachability-e2e.sh — `--target native` reachability by receiver type
# (#8413).  A call `v.equalsCaseInsensitive(w)` on a user record `Vec3` must not mark
# `Std.String.equalsCaseInsensitive` (same name and arity, a free function over `String`)
# reachable, while `s.equalsCaseInsensitive(t)` on a `String` still must.  Asserts both on
# the emitted LLVM IR and on the program output.
#
# Usage: bash scripts/ci/native-reachability-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${LYRIC_BIN:-./bin/lyric}"
if [ ! -x "$lyric_bin" ]; then
  BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
  lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
fi
[ -x "$lyric_bin" ] || { echo "::error::lyric binary not found"; exit 1; }
command -v clang >/dev/null || { echo "::error::clang not found on the runner"; exit 1; }
if [ -z "${LYRIC_RT_PATH:-}" ]; then
  rt_build_dir="$(mktemp -d)/lyric-rt-build"
  make -C lyric-rt BUILD="$rt_build_dir"
  export LYRIC_RT_PATH="$rt_build_dir/lyric_rt.a"
fi
export LYRIC_KEEP_LL=1

work="$(mktemp -d)"

cat > "$work/own.l" <<'LYR'
package ownprobe

import Std.Console
import Std.String

record Vec3 {
  x: Int
  y: Int
  func equalsCaseInsensitive(self: in Vec3, other: in Vec3): Int { self.x + other.y }
}

func main(): Unit {
  val v: Vec3 = Vec3(x = 3, y = 4)
  Console.println(toString(v.equalsCaseInsensitive(v)))
}
LYR

cat > "$work/str.l" <<'LYR'
package strprobe

import Std.Console
import Std.String

func main(): Unit {
  val s = "abc"
  Console.println(toString(s.equalsCaseInsensitive("ABC")))
}
LYR

"$lyric_bin" build --target native "$work/own.l" -o "$work/own"
"$lyric_bin" build --target native "$work/str.l" -o "$work/str"

out="$("$work/own")"
[ "$out" = "7" ] || { echo "::error::own.l printed '$out', expected 7"; exit 1; }
out="$("$work/str")"
[ "$out" = "true" ] || { echo "::error::str.l printed '$out', expected true"; exit 1; }

if grep -q '^define .*@"\?Std\.String\.equalsCaseInsensitive' "$work/own.ll"; then
  echo "::error::Std.String.equalsCaseInsensitive was lowered for a call on a Vec3 receiver (#8413)"
  exit 1
fi
grep -q '^define .*@"\?Std\.String\.equalsCaseInsensitive' "$work/str.ll" || {
  echo "::error::Std.String.equalsCaseInsensitive was not lowered for a call on a String receiver"
  exit 1
}
grep -q '^define .*@"\?ownprobe\.Vec3\.equalsCaseInsensitive' "$work/own.ll" || {
  echo "::error::Vec3.equalsCaseInsensitive was not lowered"
  exit 1
}
echo "native reachability by receiver type: ok"
