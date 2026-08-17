#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# t0115-backstop-e2e.sh — pin both T0115 diagnostic tiers as negative
# compiles, plus the dependency-aspect-template positive path at runtime
# (#6351 / D-progress-781/782, PR #6504/#6506).
#
#   (a) the EXHAUSTED-tail panic in the EPath value-position lowering —
#       reached via the one legitimate route that bypasses the type
#       checker: a path-dependency aspect template whose advice body
#       references an undefined qualifier, woven into a consumer.  The
#       message must name the unresolved name AND the enclosing woven
#       specialization (`__lyric_bmode_...`) so failures in synthesized
#       code are locatable.
#   (b) the pre-check fast path (`diagnoseUnresolvedQualifiedValueMsil`)
#       for a plain qualified typo (`NoSuchPkg.nope`) — the
#       message-quality tier.
#   (c) positive control: an identically-shaped dep-template weave with a
#       VALID reference builds AND runs (exit 0 proves the woven advice
#       executed), so a regression that silently stops weaving — which
#       would make (a) pass vacuously — fails here instead.
#
# Binary-driven because both negatives are expected COMPILE failures,
# which a `lyric test` `@test_module` cannot host.  Runs locally too:
#   BUILD_CONFIG=Debug bash scripts/ci/t0115-backstop-e2e.sh
# or point LYRIC_BIN at any built binary (e.g. LYRIC_BIN=./bin/lyric).
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin" >&2
  exit 1
fi
bin_abs="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

write_lib() { # $1=dir $2=pkgname $3=advice-expr
  mkdir -p "$work/$1/src"
  cat > "$work/$1/lyric.toml" <<TOML
[package]
name = "$2"
version = "0.1.0"
[project]
name = "$2"
output = "single"
output_assembly = "$2.dll"
[project.packages]
"$2" = "src/lib.l"
TOML
  cat > "$work/$1/src/lib.l" <<EOF
package $2

import Std.Core

pub func fallbackValue(tag: in String): Result[Int, String] {
  Err("fallback: " + tag)
}

pub aspect Advice {
  config {
    enabled: Bool = true
  }
  around(call) -> ret {
    if enabled {
      ret = $3
    } else {
      ret = call.proceed()
    }
  }
}
EOF
}

write_app() { # $1=dir $2=pkgname $3=libname $4=ok-arm $5=err-arm
  mkdir -p "$work/$1/src"
  cat > "$work/$1/lyric.toml" <<TOML
[package]
name = "$2"
version = "0.1.0"
[project]
name = "$2"
output = "single"
output_assembly = "$2.dll"
[project.packages]
"$2" = "src/main.l"
[dependencies]
$3 = { path = "../lib-$1" }
TOML
  cat > "$work/$1/src/main.l" <<EOF
package $2

import Std.Core
import $3

aspect Applied from $3.Advice {
  matches: name like "handle*"
}

func handle(x: in Int): Result[Int, String] {
  Ok(x + 1)
}

pub func main(): Int {
  match handle(1) {
    case Ok(_) -> $4
    case Err(m) -> $5
  }
}
EOF
}

# (a) NEGATIVE: undefined qualifier in the dep template's advice body.
write_lib "lib-bad" "Badlib" 'Err(Nonexistent.unauthorized("boom"))'
write_app "bad" "BadApp" "Badlib" "2" "1"
( cd "$work/lib-bad" && timeout 180 "$bin_abs" build --manifest lyric.toml ) > "$work/libbad.out" 2>&1 || {
  echo "--- lib-bad build ---"; cat "$work/libbad.out"
  echo "library with an unwoven broken template should still build"; exit 1; }
rc=0
( cd "$work/bad" && timeout 60 "$bin_abs" restore && timeout 180 "$bin_abs" build --manifest lyric.toml ) > "$work/bad.out" 2>&1 || rc=$?
echo "--- negative (tail) build output (rc=$rc) ---"; cat "$work/bad.out"
test "$rc" -ne 0 || { echo "woven undefined qualifier should fail the build"; exit 1; }
grep -q "error\[T0115\]: cannot resolve name 'Nonexistent'" "$work/bad.out" || {
  echo "expected the exhausted-tail T0115 naming 'Nonexistent'"; exit 1; }
grep -q "__lyric_bmode_Badlib_Advice" "$work/bad.out" || {
  echo "expected the T0115 message to name the woven specialization function"; exit 1; }

# (b) NEGATIVE: plain qualified typo hits the precise pre-check tier.
mkdir -p "$work/typo"
printf 'package Typo\n\nimport Std.Core\n\nfunc main(): Int {\n  val x = NoSuchPkg.nope\n  0\n}\n' > "$work/typo/main.l"
rc=0
( cd "$work/typo" && timeout 180 "$bin_abs" build main.l ) > "$work/typo.out" 2>&1 || rc=$?
echo "--- negative (pre-check) build output (rc=$rc) ---"; cat "$work/typo.out"
test "$rc" -ne 0 || { echo "qualified typo should fail the build"; exit 1; }
grep -q "cannot resolve qualified reference 'NoSuchPkg.nope'" "$work/typo.out" || {
  echo "expected the pre-check qualified-reference T0115 message"; exit 1; }

# (c) POSITIVE control: valid dep-template weave builds and RUNS.
write_lib "lib-good" "Goodlib" 'Goodlib.fallbackValue("guarded")'
write_app "good" "GoodApp" "Goodlib" "2" 'if m == "fallback: guarded" { 0 } else { 3 }'
( cd "$work/lib-good" && timeout 180 "$bin_abs" build --manifest lyric.toml ) > "$work/libgood.out" 2>&1 || {
  echo "--- lib-good build ---"; cat "$work/libgood.out"; echo "good library should build"; exit 1; }
( cd "$work/good" && timeout 60 "$bin_abs" restore && timeout 180 "$bin_abs" build --manifest lyric.toml ) > "$work/good.out" 2>&1 || {
  echo "--- good build ---"; cat "$work/good.out"; echo "valid dep-template weave should build"; exit 1; }
( cd "$work/good" && timeout 60 dotnet exec bin/GoodApp.dll ) > "$work/goodrun.out" 2>&1
grc=$?
echo "--- positive run (rc=$grc) ---"; cat "$work/goodrun.out"
test "$grc" -eq 0 || { echo "woven advice did not execute (expected exit 0 via the Err fallback arm)"; exit 1; }
echo "T0115 exhausted-tail backstop e2e passed"
