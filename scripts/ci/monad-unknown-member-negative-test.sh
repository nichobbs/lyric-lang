#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# monad-unknown-member-negative-test.sh - a bare member of Result/Option that
# names none of their accessors is a compile-time T0113 (#8472).
#
# Lyric has no trailing-lambda call syntax, so `r.mapErr { e -> ... }` parses as
# the bare member `r.mapErr` followed by a block. `lyric check` used to accept
# it and the program failed at run time with "unsupported method 'mapErr'".
# This checks the diagnostic, that the real accessors and a call written with
# parentheses are not flagged, and that a function named like the member (a
# UFCS call) is not flagged either.
#
# Usage: LYRIC_BIN=<path> bash scripts/ci/monad-unknown-member-negative-test.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping monad unknown-member test"
  exit 1
fi
bin_abs="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/bad.l" <<'LYR'
package MonadBad

import Std.Core

func f(r: in Result[Int, String]): Result[Int, Int] {
  val x = r.mapErr { e -> 1 }
  return Err(error = 1)
}

func g(o: in Option[Int]): Int {
  val y = o.frobnicate { v -> 1 }
  return 0
}

func main(): Unit {
  println("unreachable")
}
LYR

cat > "$work/good.l" <<'LYR'
package MonadGood

import Std.Core

func mapTwice(r: in Result[Int, String]): Int {
  return 2
}

func f(r: in Result[Int, String], o: in Option[Int]): Bool {
  val a = r.isOk
  val b = r.isErr
  val c = o.isSome
  val d = o.isNone
  val e = r.mapTwice()
  return a or b or c or d or e == 2
}

func main(): Unit {
  println("ok")
}
LYR

set +e
out="$(cd "$work" && "$bin_abs" check bad.l 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: bad.l was accepted"
  echo "$out"
  exit 1
fi
for want in "bad.l: error[T0113] 6:11: no member 'mapErr' on type 'Result'" "error[T0113] 11:11: no member 'frobnicate' on type 'Option'"; do
  if ! grep -qF -- "$want" <<<"$out"; then
    echo "FAIL: expected diagnostic not found: $want"
    echo "$out"
    exit 1
  fi
done

if ! out="$(cd "$work" && "$bin_abs" check good.l 2>&1)"; then
  echo "FAIL: good.l was rejected"
  echo "$out"
  exit 1
fi
echo "PASS: unknown Result/Option members are T0113; accessors and calls are accepted"
