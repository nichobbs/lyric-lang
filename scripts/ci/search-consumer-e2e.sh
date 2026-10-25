#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# search-consumer-e2e.sh: a project that declares `Lyric.Search` as a
# `[dependencies]` entry builds, runs and tests on both targets (#7668).
#
# `Search`'s contract once named `Std.Json.JsonElement` in public signatures
# without recording an import that resolved it, so restoring the DLL failed
# with "synthesised contract source did not type-check".  `lyric test` of the
# consumer also read the directory-form package `"Search" = "src"` as a file
# and printed "Access to the path ... is denied" for it.
#
#   bash scripts/ci/search-consumer-e2e.sh
# LYRIC_BIN overrides the binary (default: the AOT build for BUILD_CONFIG).
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
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/app/src" "$work/app/tests"

fail=0
if ! "$lyric_bin" build --manifest "$REPO_ROOT/lyric-search/lyric.toml" >"$work/lib.log" 2>&1; then
  echo "FAIL: lyric-search did not build"; cat "$work/lib.log"; exit 1
fi

cat > "$work/app/lyric.toml" <<TOML
[package]
name = "Search.Consumer"
version = "0.1.0"
[project]
name = "Search.Consumer"
output = "single"
output_assembly = "SearchConsumer.dll"
[project.packages]
"SearchConsumer" = "src/app.l"
[project.tests]
"SearchConsumer.Tests" = "tests/app_tests.l"
[dependencies]
"Lyric.Search" = { path = "$REPO_ROOT/lyric-search" }
TOML
cat > "$work/app/src/app.l" <<'EOF'
package SearchConsumer

import Std.Core
import Search

func main(): Int {
  val q = Search.makeQuery("books", "lyric")
  match Search.validateSearchQuery(q) {
    case Some(_) -> println("invalid")
    case None -> println("valid")
  }
  0
}
EOF
cat > "$work/app/tests/app_tests.l" <<'EOF'
@test_module
package SearchConsumer.Tests

import Std.Core
import Search

test "the restored Search surface resolves" {
  val q = Search.makeQuery("books", "lyric")
  assert(Search.validateSearchQuery(q) == None)
}
EOF

for target in dotnet jvm; do
  out="$("$lyric_bin" run --target "$target" --manifest "$work/app/lyric.toml" 2>&1)"
  if [ "$(echo "$out" | tail -1)" != "valid" ]; then
    echo "FAIL: run --target $target: expected 'valid', got:"; echo "$out"; fail=1
  fi
  out="$("$lyric_bin" test --target "$target" --manifest "$work/app/lyric.toml" 2>&1)"
  if ! echo "$out" | grep -q "1 passed, 0 failed"; then
    echo "FAIL: test --target $target:"; echo "$out"; fail=1
  fi
  if echo "$out" | grep -q "is denied\|cannot read source"; then
    echo "FAIL: test --target $target reported a spurious dependency-source I/O error:"; echo "$out"; fail=1
  fi
done

[ "$fail" -eq 0 ] && echo "Lyric.Search consumer on dotnet and jvm: ok"
exit "$fail"
