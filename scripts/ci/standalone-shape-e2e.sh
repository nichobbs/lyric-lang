#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# standalone-shape-e2e.sh — `lyric build --shape standalone` (docs/63 §5.1,
# #6262).
#
#   bash scripts/ci/standalone-shape-e2e.sh [dotnet] [jvm]
#
# Builds a program with `--shape standalone` on each managed target and runs
# the result with a scrubbed environment: no DOTNET_ROOT, no JAVA_HOME, and a
# PATH that holds neither `dotnet` nor `java`.  The .NET artifact must start
# from its apphost alone; the JVM artifact must start from its own `jlink`
# runtime image.  A `--define` is threaded into the staging build, and
# rebuilding into the same directory replaces it.  With no arguments both
# targets are checked.  Linux only (the shapes' supported hosts).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the standalone shape e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/hello.l" <<'EOF2'
package StandaloneHello

import Std.Environment as Environment

@build_const("greeting")
val GREETING: String = "default"

func main(): Int {
  println("hello from ${GREETING}")
  val args = Environment.args()
  println("last ${args[args.length - 1]}")
  0
}
EOF2

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(dotnet jvm)
fi

# A PATH with the basics (sh, dirname, readlink, pwd) and no runtime: a
# private directory of symlinks to just those tools.
bin="$work/bin"
mkdir -p "$bin"
for tool in sh dirname readlink cat; do
  ln -s "$(command -v "$tool")" "$bin/$tool"
done

fail=0
for target in "${targets[@]}"; do
  out="$work/out-$target/app"
  if ! "$lyric_bin" build --target "$target" --shape standalone --define greeting=standalone \
      "$work/hello.l" -o "$out" >"$work/build.log" 2>&1; then
    echo "::error::--shape standalone build failed on --target $target" >&2
    cat "$work/build.log" >&2
    fail=1
    continue
  fi
  if [[ ! -x "$out/app" ]]; then
    echo "::error::--target $target: $out/app is not an executable" >&2
    ls -la "$out" >&2
    fail=1
    continue
  fi
  if ! env -i PATH="$bin" HOME="$work" "$out/app" one two >"$work/run.log" 2>&1; then
    echo "::error::--target $target: the standalone artifact failed to run without a runtime installed" >&2
    cat "$work/run.log" >&2
    fail=1
    continue
  fi
  if ! grep -qx "hello from standalone" "$work/run.log" || ! grep -qx "last two" "$work/run.log"; then
    echo "::error::--target $target: unexpected output (the --define or the arguments did not arrive)" >&2
    cat "$work/run.log" >&2
    fail=1
    continue
  fi
  # A rebuild replaces the directory it wrote earlier...
  if ! "$lyric_bin" build --target "$target" --shape standalone "$work/hello.l" -o "$out" >"$work/build.log" 2>&1; then
    echo "::error::--target $target: rebuilding into the same directory failed" >&2
    cat "$work/build.log" >&2
    fail=1
    continue
  fi
  # ...and refuses to clear a directory it did not write.
  mkdir -p "$work/precious"
  echo keep > "$work/precious/data.txt"
  if "$lyric_bin" build --target "$target" --shape standalone "$work/hello.l" -o "$work/precious" >"$work/build.log" 2>&1 \
      || [[ ! -f "$work/precious/data.txt" ]]; then
    echo "::error::--target $target: a foreign non-empty output directory must be refused untouched" >&2
    cat "$work/build.log" >&2
    fail=1
  fi
  rm -rf "$work/precious"

  # Project mode: the staging artifact is named after `output_assembly`
  # (`*.dll` even on the JVM), which the packaging has to cope with.
  proj="$work/proj-$target"
  "$lyric_bin" init "$proj" --name Proj >"$work/build.log" 2>&1
  if ! (cd "$proj" && "$lyric_bin" build --target "$target" --shape standalone --release -o dist/proj) >"$work/build.log" 2>&1; then
    echo "::error::--target $target: the project-mode standalone build failed" >&2
    cat "$work/build.log" >&2
    fail=1
    continue
  fi
  if ! env -i PATH="$bin" HOME="$work" "$proj/dist/proj/proj" >"$work/run.log" 2>&1 \
      || ! grep -qx "Hello from Proj!" "$work/run.log"; then
    echo "::error::--target $target: the project-mode standalone artifact did not run" >&2
    cat "$work/run.log" >&2
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "--shape standalone runs without an installed runtime on: ${targets[*]}"
