#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# private-helper-carry-e2e.sh — a `pub` generic of a built library calls the
# private helpers of its own package from another package (#8427, D215, D273).
# Run on both targets.
#
# A generic function's body is compiled into each package that calls it, where
# a private function of the declaring package cannot be bound.  The helpers a
# `pub` generic reaches travel with it under package-unique names:
#   - private generic helpers (D215), directly and through another helper;
#   - self-contained private non-generic helpers (D273).
# A private non-generic helper that reads module-level state is not copied (a
# copy would hold its own instance of the state) and stays T0123, which the
# negative leg pins.
#
# Usage: BUILD_CONFIG=Release scripts/ci/private-helper-carry-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lyric_bin="$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

write_lib() {
  dir="$1"
  mkdir -p "$dir/src"
  cat > "$dir/lyric.toml" <<'EOF'
[package]
name = "Carry.Lib"
version = "0.1.0"

[project]
name = "Carry.Lib"
output = "single"
output_assembly = "CarryLib.dll"

[project.packages]
"CarryLib" = "src/lib.l"
EOF
}

write_app() {
  dir="$1"
  mkdir -p "$dir/src" "$dir/tests"
  cat > "$dir/lyric.toml" <<'EOF'
[package]
name = "Carry.App"
version = "0.1.0"

[project]
name = "Carry.App"
output = "single"
output_assembly = "CarryApp.dll"

[project.packages]
"CarryApp" = "src/app.l"

[project.tests]
"CarryApp.Tests" = "tests/app_tests.l"

[dependencies]
"Carry.Lib" = { path = "../lib" }
EOF
}

# --- positive: private generic and self-contained non-generic helpers ---
mkdir -p "$work/ok"
write_lib "$work/ok/lib"
cat > "$work/ok/lib/src/lib.l" <<'EOF'
package CarryLib

func scale(n: Int): Int { n * 10 }
func bump(n: Int): Int { scale(n) + 1 }
func inner[S](x: S, f: (S) -> Int): Int { f(x) + bump(1) }

pub func outer[S](x: S, f: (S) -> Int): Int { inner(x, f) + 1 }
pub func outer2[S](x: S, f: (S) -> Int): Int { scale(f(x)) }
pub func viaLambda[S](x: S, f: (S) -> Int): Int {
  val body: (Int) -> Int = { n: Int -> bump(n) }
  body(f(x))
}
pub func applyIt[S](scale: (S) -> S, x: S): S { scale(x) }
EOF
write_app "$work/ok/app"
cat > "$work/ok/app/src/app.l" <<'EOF'
package CarryApp

import CarryLib

pub func run(): Int {
  outer(5, { v: Int -> v * 2 })
}
EOF
cat > "$work/ok/app/tests/app_tests.l" <<'EOF'
@test_module
package CarryApp.Tests

import Std.Testing
import CarryApp
import CarryLib

test "a pub generic reaches a private generic, which reaches a private helper" {
  assertEqualInt(CarryApp.run(), 22, "inner(5) + 1 = 10 + 11 + 1")
}

test "a pub generic reaches a private non-generic helper" {
  assertEqualInt(CarryLib.outer2(3, { v: Int -> v + 1 }), 40, "scale(4)")
}

test "a helper reached from a lambda of a pub generic" {
  assertEqualInt(CarryLib.viaLambda(7, { v: Int -> v + 1 }), 81, "bump(8)")
}

test "a parameter named like a helper is not a call to it" {
  assertEqualInt(CarryLib.applyIt({ n: Int -> n + 1 }, 4), 5, "the parameter was called")
}
EOF
"$lyric_bin" build --manifest "$work/ok/lib/lyric.toml"
for target in dotnet jvm; do
  echo "=== --target $target"
  "$lyric_bin" test --target "$target" --manifest "$work/ok/app/lyric.toml"
done

# --- negative: a helper that reads module state is not copied ---
mkdir -p "$work/state"
write_lib "$work/state/lib"
cat > "$work/state/lib/src/lib.l" <<'EOF'
package CarryLib

val counter: Int = 41
func readsState(n: Int): Int { n + counter }

pub func outer[S](x: S, f: (S) -> Int): Int { readsState(f(x)) }
EOF
write_app "$work/state/app"
cat > "$work/state/app/src/app.l" <<'EOF'
package CarryApp

import CarryLib

pub func run(): Int {
  outer(1, { v: Int -> v })
}
EOF
cat > "$work/state/app/tests/app_tests.l" <<'EOF'
@test_module
package CarryApp.Tests

import Std.Testing
import CarryApp

test "unreachable" {
  assertEqualInt(CarryApp.run(), 42, "unreachable")
}
EOF
"$lyric_bin" build --manifest "$work/state/lib/lyric.toml"
for target in dotnet jvm; do
  echo "=== --target $target (negative)"
  if out="$("$lyric_bin" test --target "$target" --manifest "$work/state/app/lyric.toml" 2>&1)"; then
    echo "::error::a helper that reads module state was copied on --target $target"
    exit 1
  fi
  case "$out" in
    *T0123*readsState*) ;;
    *)
      echo "::error::expected T0123 naming 'readsState' on --target $target, got:"
      echo "$out"
      exit 1
      ;;
  esac
done
echo "private helpers of a pub generic cross the package boundary on both targets"
