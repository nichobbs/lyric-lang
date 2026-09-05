#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; native AOT smoke test cannot run"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
dir="$(mktemp -d)"
src="$dir/hello.l"
# Also asserts the well-known `build_profile` define (docs/60 M1h,
# #5852): a real --release --aot build injects build_profile=release into
# the staging compile, so BuildInfo.profile reports "release" in the
# native binary. This is the load-bearing guard for the release-path
# injection, and this job (unlike `build`) has clang/ILCompiler.
cat > "$src" <<'LYRIC'
package Hello
import Std.Core
import Std.BuildInfo
func main(): Int {
  println("hello-aot")
  println("profile=" + buildInfo().profile)
  0
}
LYRIC
native_bin="$dir/hello"
"$lyric_bin" build --release --aot "$src" -o "$native_bin"
if [ ! -x "$native_bin" ]; then
  echo "::error::native binary not produced at $native_bin"
  exit 1
fi
out="$("$native_bin" 2>&1)"
echo "native AOT output: $out"
echo "$out" | grep -qx "hello-aot" || { echo "::error::native AOT smoke test did not print hello-aot; got: '$out'"; exit 1; }
echo "$out" | grep -qx "profile=release" || { echo "::error::--release --aot build did not inject build_profile=release (#5852 M1h); got: '$out'"; exit 1; }
echo "OK: native AOT binary produced and executed correctly (hello-aot + build_profile=release)." >> "$GITHUB_STEP_SUMMARY"

