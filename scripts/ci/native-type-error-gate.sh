#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-type-error-gate.sh — a type error stops every `--target native`
# entry point (#7910).
#
#   LYRIC_BIN=<lyric> LYRIC_RT_PATH=<lyric_rt.a> bash scripts/ci/native-type-error-gate.sh
#
# The native bridge used to run the type check as advisory: it printed
# error[T....] and still linked and ran the binary.  This checks that an
# ill-typed program fails `lyric build`, `lyric run`, `lyric test`, a
# `--define` build, and a project build (own package and a path dependency
# compiled from source), each with a non-zero exit, the error[T....] line,
# and no binary or program output; and that a clean program, and one whose
# only diagnostic is a warning (W0002), still builds and runs.  Invoked from
# `native-target-smoke-test.sh`, which builds the runtime it links against.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the native type-error gate" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# expect_rejected <label> <log> <rc> <artifact-or-empty>
expect_rejected() {
  local label="$1" log="$2" rc="$3" artifact="$4" bad=0
  if [ "$rc" -eq 0 ]; then
    echo "::error::$label: expected a non-zero exit for an ill-typed program, got 0" >&2
    bad=1
  fi
  if ! grep -q 'error\[T0042\]' "$log" || ! grep -q 'error\[T0060\]' "$log"; then
    echo "::error::$label: expected the error[T0042] and error[T0060] diagnostics" >&2
    bad=1
  fi
  if grep -q 'ILL-TYPED-PROGRAM-RAN' "$log"; then
    echo "::error::$label: the ill-typed program ran" >&2
    bad=1
  fi
  if [ -n "$artifact" ] && [ -e "$artifact" ]; then
    echo "::error::$label: a binary was written at $artifact" >&2
    bad=1
  fi
  if [ "$bad" -ne 0 ]; then
    cat "$log" >&2
    fail=1
  else
    echo "native type-error gate ($label): OK"
  fi
}

# `println()` is T0042 and `val b: Bool = 1` is T0060 on every target.  The
# native backend lowers both, so before #7910 this program linked and ran.
cat > "$work/bad.l" <<'LYR'
package NativeTypeErrorGate

import Std.Console

func main(): Int {
  println("ILL-TYPED-PROGRAM-RAN")
  println()
  val b: Bool = 1
  println(toString(b))
  0
}
LYR

set +e
"$lyric_bin" build --target native "$work/bad.l" -o "$work/bad" >"$work/build.log" 2>&1
rc=$?
set -e
expect_rejected "build" "$work/build.log" "$rc" "$work/bad"

cat > "$work/bad_define.l" <<'LYR'
package NativeTypeErrorGateDefine

import Std.Console

@build_const("greeting")
val GREETING: String = "default"

func main(): Int {
  println("ILL-TYPED-PROGRAM-RAN " + GREETING)
  println()
  val b: Bool = 1
  println(toString(b))
  0
}
LYR
set +e
"$lyric_bin" build --target native "$work/bad_define.l" --define greeting=hello -o "$work/bad-define" >"$work/define.log" 2>&1
rc=$?
set -e
expect_rejected "build --define" "$work/define.log" "$rc" "$work/bad-define"

set +e
"$lyric_bin" run --target native "$work/bad.l" >"$work/run.log" 2>&1
rc=$?
set -e
expect_rejected "run" "$work/run.log" "$rc" ""

cat > "$work/bad_test.l" <<'LYR'
@test_module
package NativeTypeErrorGateTest

import Std.Console
import Std.Testing

test "ill-typed" {
  println("ILL-TYPED-PROGRAM-RAN")
  println()
  val b: Bool = 1
  assertTrue(b, "never reached")
}
LYR
set +e
"$lyric_bin" test --target native "$work/bad_test.l" >"$work/test.log" 2>&1
rc=$?
set -e
expect_rejected "test" "$work/test.log" "$rc" ""

# Project builds: the error in the project's own package, then in a path
# dependency the native build compiles from source (#7833).
mkdir -p "$work/proj/src"
cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "NativeTypeErrorGate"
version = "0.1.0"

[project]
name = "NativeTypeErrorGate"

[project.packages]
"NativeTypeErrorGate" = "src/main.l"
TOML
cp "$work/bad.l" "$work/proj/src/main.l"
set +e
"$lyric_bin" build --manifest "$work/proj/lyric.toml" --target native -o "$work/proj-bad" >"$work/proj.log" 2>&1
rc=$?
set -e
expect_rejected "project build" "$work/proj.log" "$rc" "$work/proj-bad"

mkdir -p "$work/dep/src" "$work/app/src"
cat > "$work/dep/lyric.toml" <<'TOML'
[package]
name = "NativeGateDep"
version = "0.1.0"

[project]
name = "NativeGateDep"

[project.packages]
"NativeGateDep" = "src/main.l"
TOML
cat > "$work/dep/src/main.l" <<'LYR'
package NativeGateDep

pub func depWord(): String {
  println()
  val b: Bool = 1
  toString(b)
}
LYR
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "NativeGateApp"
version = "0.1.0"

[project]
name = "NativeGateApp"

[project.packages]
"NativeGateApp" = "src/main.l"

[dependencies]
"NativeGateDep" = { path = "../dep" }
TOML
cat > "$work/app/src/main.l" <<'LYR'
package NativeGateApp

import Std.Console
import NativeGateDep

func main(): Int {
  println("ILL-TYPED-PROGRAM-RAN")
  println(depWord())
  0
}
LYR
set +e
"$lyric_bin" build --manifest "$work/app/lyric.toml" --target native -o "$work/app-bad" >"$work/dep.log" 2>&1
rc=$?
set -e
expect_rejected "project build, path dependency" "$work/dep.log" "$rc" "$work/app-bad"

# A clean program, and one whose only diagnostic is the W0002 warning (a
# contract quantifier is not checked at runtime), both build and run.
cat > "$work/good.l" <<'LYR'
package NativeTypeErrorGateOk

import Std.Console

func double(n: in Int): Int
  requires: n > 0 and forall (i: Int) where i > 0 and i < n { i < n }
{
  n * 2
}

func main(): Int {
  println("native-gate-ok " + toString(double(21)))
  0
}
LYR
set +e
"$lyric_bin" build --target native "$work/good.l" -o "$work/good" >"$work/good.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] || [ ! -x "$work/good" ]; then
  echo "::error::a well-typed program with only a warning failed the native build (exit $rc)" >&2
  cat "$work/good.log" >&2
  fail=1
elif ! grep -q 'warning\[W0002\]' "$work/good.log"; then
  echo "::error::expected the W0002 warning from the native build" >&2
  cat "$work/good.log" >&2
  fail=1
else
  out="$("$work/good")"
  if [ "$out" != "native-gate-ok 42" ]; then
    echo "::error::the well-typed native binary printed '$out'" >&2
    fail=1
  else
    echo "native type-error gate (clean build + run, warning only): OK"
  fi
fi
set +e
run_out="$("$lyric_bin" run --target native "$work/good.l" 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] || ! printf '%s\n' "$run_out" | grep -qx 'native-gate-ok 42'; then
  echo "::error::lyric run --target native on a well-typed program failed (exit $rc):" >&2
  printf '%s\n' "$run_out" >&2
  fail=1
else
  echo "native type-error gate (clean lyric run): OK"
fi

exit "$fail"
