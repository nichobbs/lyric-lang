#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# single-file-features-aot-e2e.sh — `lyric build --aot <file>` compiles its
# staging build with the file's features (D182, #8339): those of the
# manifest above the file, whether or not it lists the file, under the
# command line's `--features` / `--no-default-features`.
#
#   BUILD_CONFIG=Release bash scripts/ci/single-file-features-aot-e2e.sh
#
# Needs the Native AOT toolchain (`clang`), so it runs in the e2e-cli-tests
# job beside the other `--aot` e2e.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin" >&2
  exit 1
fi
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
mkdir -p "$work/proj/src/p" "$work/proj/tools"
cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "AotFeatures"
version = "0.1.0"

[project]
name = "AotFeatures"
output = "single"
output_assembly = "AotFeatures.dll"

[project.packages]
"P" = "src/p"

[features]
default = ["wide"]
wide = []
TOML
cat > "$work/proj/src/p/p.l" <<'EOF'
package P

pub func one(): Int {
  1
}
EOF
cat > "$work/proj/tools/show.l" <<'EOF'
package Show

@cfg(feature = "wide")
func limit(): Int {
  1000
}

@cfg(not(feature = "wide"))
func limit(): Int {
  10
}

func main(): Unit {
  println(toString(limit()))
}
EOF

check() {
  local label="$1" want="$2"; shift 2
  rm -f "$work/proj/tools/show"
  "$lyric_bin" build --aot "$work/proj/tools/show.l" "$@"
  [ -x "$work/proj/tools/show" ] || { echo "FAIL: $label: expected the native binary"; exit 1; }
  local got
  got="$("$work/proj/tools/show")"
  [ "$got" = "$want" ] || { echo "FAIL: $label: expected $want, got '$got'"; exit 1; }
  echo "PASS: $label"
}

check "build --aot, the manifest's default feature" 1000
check "build --aot --no-default-features" 10 --no-default-features
check "build --aot --no-default-features --features wide" 1000 --no-default-features --features wide
echo "single-file features AOT e2e passed"
