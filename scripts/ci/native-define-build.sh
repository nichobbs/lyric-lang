#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-define-build.sh — `lyric build --target native --define` end-to-end
# (docs/60 #5977): with both native-codegen gaps closed (list literals +
# module-level `val` inlining), the CLI gate is lifted, so a `--define`
# feeds a `@build_const` val on native. Asserts the in-source fallback (no
# --define) and the substituted value (--define) in the actual native
# binary.
#
# Extracted from `.github/workflows/ci.yml`'s "native-backend-self-tests"
# job to keep the workflow file under GitHub's undocumented workflow-file
# size ceiling (issue #6781; see scripts/ci/check-workflow-size.sh's header).
#
# Usage: bash scripts/ci/native-define-build.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping native --define build"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
command -v clang >/dev/null || { echo "::error::clang not found on the runner"; exit 1; }
rt_build_dir="$(mktemp -d)/lyric-rt-build"
make -C lyric-rt BUILD="$rt_build_dir"
export LYRIC_RT_PATH="$rt_build_dir/lyric_rt.a"
work="$(mktemp -d)"
cat > "$work/greet.l" <<'LYR'
package greetprobe

import Std.Console

@build_const("greeting")
val GREETING: String = "default"

func main(): Int {
  println(GREETING)
  0
}
LYR
echo "=== --target native, no --define (expect default) ==="
"$lyric_bin" build --target native "$work/greet.l" -o "$work/greet1"
out1="$("$work/greet1")"
echo "native no-define: $out1"
[ "$out1" = "default" ] || { echo "::error::native @build_const fallback wrong: '$out1'"; exit 1; }
echo "=== --target native --define greeting=hello-native (expect hello-native) ==="
"$lyric_bin" build --target native "$work/greet.l" --define greeting=hello-native -o "$work/greet2"
out2="$("$work/greet2")"
echo "native --define: $out2"
[ "$out2" = "hello-native" ] || { echo "::error::native --define did not substitute @build_const: '$out2'"; exit 1; }
echo "Native --define build passed (fallback default + substitution hello-native)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
