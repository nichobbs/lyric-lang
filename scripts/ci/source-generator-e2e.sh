#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# source-generator-e2e.sh — a custom source generator end to end (#7834,
# D150).  examples/generators/app depends on the Acme.Describe generator in
# examples/generators/describe by path; building the app builds the
# generator for dotnet, runs it over the app's @generate(Acme.Describe)
# records, and compiles what it returns.  The app is built and run on
# --target dotnet and --target jvm, and must print the generated output; the
# generator's warning for a union it does not describe must be reported.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_CLI_PATH:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi

app="examples/generators/app"
expected=$'Order { id: Int, note: String }\nPoint { x: Long, y: Long }'

check() {
  local label="$1" actual="$2"
  if [ "$actual" != "$expected" ]; then
    echo "::error::$label printed unexpected output"
    echo "expected:"; echo "$expected"
    echo "actual:"; echo "$actual"
    exit 1
  fi
  echo "$label: ok"
}

out_dir="$(mktemp -d)"
trap 'rm -rf "$out_dir"' EXIT

"$lyric_bin" build --manifest "$app/lyric.toml" --target dotnet -o "$out_dir/dotnet/Acme.App.dll" 2> "$out_dir/build.err"
cat "$out_dir/build.err" >&2
# The generator's warning for the union is reported at its annotation.
if ! grep -q 'app.l: warning\[X0005\] [0-9]*:1: generator .Acme.Describe. on Shape \[AD001\]' "$out_dir/build.err"; then
  echo "::error::the generator's AD001 warning for Shape was not reported"
  exit 1
fi
check "dotnet" "$(dotnet "$out_dir/dotnet/Acme.App.dll")"

"$lyric_bin" build --manifest "$app/lyric.toml" --target jvm -o "$out_dir/jvm/Acme.App.jar"
check "jvm" "$(java -jar "$out_dir/jvm/Acme.App.jar" 2>/dev/null)"
