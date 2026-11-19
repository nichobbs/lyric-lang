#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-manifest-test-e2e.sh: `lyric test --manifest <lyric.toml> --target
# native` (#6815 item 3(b)).  Each `[project.tests]` entry is compiled with the
# project's packages and its path and workspace dependencies into one native
# executable and run; the command reports them as the dotnet and JVM manifest
# runs do.  A workspace with a member that depends on a sibling by
# `{ workspace = true }` and on a directory outside the workspace by `path`:
#   - every entry passes: TAP per entry, `== summary: 3 passed, 0 failed`,
#     exit 0, from the workspace root and from the member's own directory
#     (no `--manifest`: the manifest is discovered);
#   - a test module that declares the package of a `[project.packages]` entry
#     reaches its non-`pub` items;
#   - a file-level `@cfg(feature = ...)` module is reported as gated without
#     `--features`, and runs with it;
#   - `--filter` runs the matching tests and does not compile an entry none of
#     whose tests match;
#   - `--doctests` runs the doc-comment examples of the project's packages;
#   - a failing assertion: the entry's later tests cannot run (native has no
#     exception unwinding), so the command prints `not ok <n> - <title>` for
#     the test the binary stopped in and how many did not run, counts the
#     entry as failed and exits 1, and the other entries still run;
#   - `--fail-fast` stops after that entry;
#   - a package whose `[package] targets` leaves native out is refused (F0054);
#   - a registry dependency is refused, as `lyric build --target native` does.
#
#   bash scripts/ci/native-manifest-test-e2e.sh
# LYRIC_BIN overrides the binary (default: the AOT build for BUILD_CONFIG).
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin" >&2
  exit 1
fi
case "$lyric_bin" in
  /*) ;;
  *) lyric_bin="$REPO_ROOT/$lyric_bin" ;;
esac
# The binary finds the standard library from its own directory or from here.
export LYRIC_STD_PATH="${LYRIC_STD_PATH:-$REPO_ROOT/lyric-stdlib/std}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

fail() {
  echo "FAIL: $1" >&2
  failures=$((failures + 1))
}

# expect_run <label> <expected exit code | nonzero> <dir> <args...>: runs
# `lyric` in <dir>, leaves its combined output in $out.
out=""
expect_run() {
  local label="$1" want="$2" dir="$3"
  shift 3
  out="$(cd "$dir" && "$lyric_bin" "$@" 2>&1)"
  local rc=$?
  if [ "$want" = nonzero ]; then
    if [ "$rc" -eq 0 ]; then
      fail "$label: exit code 0, expected a failure"
      echo "$out" >&2
    fi
  elif [ "$rc" -ne "$want" ]; then
    fail "$label: exit code $rc, expected $want"
    echo "$out" >&2
  fi
}

expect_line() {
  if ! grep -qxF -- "$2" <<<"$out"; then
    fail "$1: missing line: $2"
    echo "$out" >&2
  fi
}

expect_text() {
  if ! grep -qF -- "$2" <<<"$out"; then
    fail "$1: missing text: $2"
    echo "$out" >&2
  fi
}

expect_no_text() {
  if grep -qF -- "$2" <<<"$out"; then
    fail "$1: unexpected text: $2"
    echo "$out" >&2
  fi
}

ws="$work/ws"
mkdir -p "$ws/shapes/src" "$ws/app/src" "$ws/app/tests" "$work/outside/src"

cat > "$ws/lyric.toml" <<'EOF'
[workspace]
EOF

# A workspace member the application depends on with `{ workspace = true }`.
cat > "$ws/shapes/lyric.toml" <<'EOF'
[package]
name = "Nmt.Shapes"
version = "0.1.0"

[project]
name = "Nmt.Shapes"

[project.packages]
"Nmt.Shapes" = "src/shapes.l"
EOF
cat > "$ws/shapes/src/shapes.l" <<'EOF'
package Nmt.Shapes

import Std.Core

pub record Rect {
  w: Int
  h: Int
}

pub func area(r: in Rect): Int {
  r.w * r.h
}
EOF

# A directory outside the workspace, depended on by `path`.
cat > "$work/outside/lyric.toml" <<'EOF'
[package]
name = "Nmt.Outside"
version = "0.1.0"

[project]
name = "Nmt.Outside"

[project.packages]
"Nmt.Outside" = "src/outside.l"
EOF
cat > "$work/outside/src/outside.l" <<'EOF'
package Nmt.Outside

import Std.Core

pub func twice(n: in Int): Int {
  n * 2
}
EOF

cat > "$ws/app/lyric.toml" <<'EOF'
[package]
name = "Nmt.App"
version = "0.1.0"

[features]
slow = []

[project]
name = "Nmt.App"

[project.packages]
"Nmt.App" = "src/app.l"

[project.tests]
"Nmt.App.Tests" = "tests/app_tests.l"
"Nmt.App.InternalTests" = "tests/internal_tests.l"
"Nmt.App.SlowTests" = "tests/slow_tests.l"
"Nmt.App.MoreTests" = "tests/more_tests.l"

[dependencies]
"Nmt.Shapes" = { workspace = true }
"Nmt.Outside" = { path = "../../outside" }
EOF
cat > "$ws/app/src/app.l" <<'EOF'
package Nmt.App

import Std.Core
import Nmt.Shapes
import Nmt.Outside

func hidden(n: in Int): Int {
  n + 1
}

/// Twice the area of a `w` by `h` rectangle.
///
/// ```lyric
/// assertEqualInt(doubledArea(2, 5), 20, "doubledArea")
/// ```
pub func doubledArea(w: in Int, h: in Int): Int {
  twice(area(Rect(w = w, h = h)))
}
EOF
cat > "$ws/app/tests/app_tests.l" <<'EOF'
@test_module
package Nmt.App.Tests

import Std.Core
import Std.Testing
import Nmt.App
import Nmt.Shapes

test "area of a rectangle" {
  assertEqualInt(area(Rect(w = 3, h = 4)), 12, "area")
}

test "the path dependency doubles it" {
  assertEqualInt(doubledArea(3, 4), 24, "doubledArea")
}

test "a Char in a message" {
  val c = 'x'
  assertEqual("got " + c, "got x", "text")
}
EOF
cat > "$ws/app/tests/internal_tests.l" <<'EOF'
@test_module
package Nmt.App

import Std.Testing

test "a non-pub item of the package" {
  assertEqualInt(hidden(41), 42, "hidden")
}
EOF
cat > "$ws/app/tests/slow_tests.l" <<'EOF'
@test_module
@cfg(feature = "slow")
package Nmt.App.SlowTests

import Std.Core
import Std.Testing
import Nmt.App

test "a slow test" {
  assertEqualInt(doubledArea(1, 1), 2, "slow")
}
EOF
cat > "$ws/app/tests/more_tests.l" <<'EOF'
@test_module
package Nmt.App.MoreTests

import Std.Core
import Std.Testing
import Nmt.App

test "one more" {
  assertEqualInt(doubledArea(2, 2), 8, "more")
}
EOF

# --- every entry passes, from the workspace root -----------------------------
expect_run "all pass" 0 "$ws" test --manifest app/lyric.toml --target native
expect_line "all pass" "== Nmt.App.Tests (tests/app_tests.l)"
expect_line "all pass" "1..3"
expect_line "all pass" "ok 1 - area of a rectangle"
expect_line "all pass" "ok 2 - the path dependency doubles it"
expect_line "all pass" "ok 3 - a Char in a message"
expect_line "all pass" "ok 1 - a non-pub item of the package"
expect_line "all pass" "ok 1 - one more"
expect_text "all pass" "tests/slow_tests.l:1: 0 test(s), module gated by inactive @cfg"
expect_line "all pass" "== summary: 3 passed, 0 failed"
expect_no_text "all pass" "building the [project.packages] library once"

# --- from the member's directory, the manifest discovered --------------------
expect_run "discovered manifest" 0 "$ws/app" test --target native
expect_line "discovered manifest" "== summary: 3 passed, 0 failed"

# --- a feature turns the gated module on -------------------------------------
expect_run "features" 0 "$ws" test --manifest app/lyric.toml --target native --features slow
expect_line "features" "ok 1 - a slow test"
expect_line "features" "== summary: 4 passed, 0 failed"

# --- --doctests adds a run per source file with doc-comment examples ---------
expect_run "doctests" 0 "$ws" test --manifest app/lyric.toml --target native --doctests
expect_text "doctests" "== doctests Nmt.App app.l"
expect_text "doctests" "ok 1 - doctest "
expect_line "doctests" "== summary: 4 passed, 0 failed"

# --- --filter ----------------------------------------------------------------
expect_run "filter" 0 "$ws" test --manifest app/lyric.toml --target native --filter "the path"
expect_line "filter" "# skip 1 - area of a rectangle (filter)"
expect_line "filter" "ok 2 - the path dependency doubles it"
expect_line "filter" "1 test(s), none match --filter; not compiled"
expect_line "filter" "== summary: 1 passed, 0 failed, 2 not run (no test matches --filter)"

# --- a failing assertion ends its entry; the others still run ----------------
cat > "$ws/app/tests/app_tests.l" <<'EOF'
@test_module
package Nmt.App.Tests

import Std.Core
import Std.Testing
import Nmt.App
import Nmt.Shapes

test "area of a rectangle" {
  assertEqualInt(area(Rect(w = 3, h = 4)), 12, "area")
}

test "the path dependency doubles it" {
  assertEqualInt(doubledArea(3, 4), 25, "doubledArea")
}

test "never reached" {
  assertEqualInt(1, 1, "one")
}

test "never reached either" {
  assertEqualInt(2, 2, "two")
}
EOF
expect_run "failing test" 1 "$ws" test --manifest app/lyric.toml --target native
expect_line "failing test" "ok 1 - area of a rectangle"
expect_line "failing test" "not ok 2 - the path dependency doubles it"
expect_text "failing test" "doubledArea"
expect_text "failing test" "--target native has no exception unwinding, so a failed assertion or panic ends the whole test module; 2 later test(s) of it did not run"
expect_no_text "failing test" "ok 3 - never reached"
expect_line "failing test" "ok 1 - one more"
expect_line "failing test" "== summary: 2 passed, 1 failed"

expect_run "fail fast" 1 "$ws" test --manifest app/lyric.toml --target native --fail-fast
expect_line "fail fast" "not ok 2 - the path dependency doubles it"
expect_no_text "fail fast" "ok 1 - one more"
expect_line "fail fast" "== summary: 0 passed, 1 failed (stopped early)"

# --- a single test file reports a stopped binary the same way ----------------
cat > "$work/single_tests.l" <<'EOF'
@test_module
package Nmt.Single

import Std.Core
import Std.Testing

test "first" {
  assertEqualInt(1, 1, "one")
}

test "second" {
  assertTrue(false, "second fails")
}
EOF
# Its exit code is the binary's own, which a panic sets per platform.
expect_run "single file" nonzero "$work" test single_tests.l --target native
expect_line "single file" "ok 1 - first"
expect_line "single file" "not ok 2 - second"
expect_text "single file" "second fails"

# --- [package] targets -------------------------------------------------------
mkdir -p "$work/jvmonly/src" "$work/jvmonly/tests"
cat > "$work/jvmonly/lyric.toml" <<'EOF'
[package]
name = "Nmt.JvmOnly"
version = "0.1.0"
targets = ["jvm"]

[project]
name = "Nmt.JvmOnly"

[project.packages]
"Nmt.JvmOnly" = "src/lib.l"

[project.tests]
"Nmt.JvmOnly.Tests" = "tests/lib_tests.l"
EOF
cat > "$work/jvmonly/src/lib.l" <<'EOF'
package Nmt.JvmOnly

pub func one(): Int {
  1
}
EOF
cat > "$work/jvmonly/tests/lib_tests.l" <<'EOF'
@test_module
package Nmt.JvmOnly.Tests

import Std.Testing
import Nmt.JvmOnly

test "one" {
  assertEqualInt(one(), 1, "one")
}
EOF
expect_run "targets" 1 "$work/jvmonly" test --manifest lyric.toml --target native
expect_text "targets" "F0054"

# --- a registry dependency has no source for a native build ------------------
mkdir -p "$work/registry/src" "$work/registry/tests"
cat > "$work/registry/lyric.toml" <<'EOF'
[package]
name = "Nmt.Registry"
version = "0.1.0"

[project]
name = "Nmt.Registry"

[project.packages]
"Nmt.Registry" = "src/lib.l"

[project.tests]
"Nmt.Registry.Tests" = "tests/lib_tests.l"

[dependencies]
"Some.Package" = "1.0.0"
EOF
cp "$work/jvmonly/src/lib.l" "$work/registry/src/lib.l"
sed -i.bak 's/Nmt.JvmOnly/Nmt.Registry/' "$work/registry/src/lib.l"
sed 's/Nmt.JvmOnly/Nmt.Registry/g' "$work/jvmonly/tests/lib_tests.l" > "$work/registry/tests/lib_tests.l"
expect_run "registry dependency" 1 "$work/registry" test --manifest lyric.toml --target native
expect_text "registry dependency" "dependency 'Some.Package' is a registry dependency; --target native compiles Lyric dependencies from source"

if [ "$failures" -gt 0 ]; then
  echo "native-manifest-test-e2e: $failures failure(s)" >&2
  exit 1
fi
echo "native-manifest-test-e2e: ok"
