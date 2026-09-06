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
mkdir -p "$dir/src/app" "$dir/src/helper"
cat > "$dir/lyric.toml" <<'TOML'
[package]
name = "ReleaseNugetSmoke"
version = "0.1.0"
[project]
name = "ReleaseNugetSmoke"
output = "single"
output_assembly = "ReleaseNugetSmoke.dll"
[project.packages]
"ReleaseNugetSmoke" = "src/app/main.l"
"ReleaseNugetSmoke.Helper" = "src/helper/helper.l"
[nuget]
"Newtonsoft.Json" = "13.0.3"
TOML
cat > "$dir/src/helper/helper.l" <<'LYRIC'
package ReleaseNugetSmoke.Helper
pub func addOne(x: Int): Int {
  x + 1
}
LYRIC
# `main.l` also asserts the well-known `build_profile` define on the
# MULTI-PACKAGE release path (`buildReleaseProject`, docs/60 M1h #5852):
# its staging compile injects build_profile=release, so BuildInfo.profile
# reports "release" in the native binary (the single-file path is guarded
# by the hello-world smoke test above; this covers buildReleaseProject).
cat > "$dir/src/app/main.l" <<'LYRIC'
package ReleaseNugetSmoke
import Std.Core
import Std.BuildInfo
import ReleaseNugetSmoke.Helper
extern type JsonConvert = "Newtonsoft.Json.JsonConvert"
pub func main(): Int {
  println(JsonConvert.SerializeObject("hi"))
  println(addOne(41).toString())
  println("profile=" + buildInfo().profile)
  0
}
LYRIC
(cd "$dir" && "$OLDPWD/$lyric_bin" restore)
(cd "$dir" && "$OLDPWD/$lyric_bin" build --release --aot --rid linux-x64)
native_bin="$dir/ReleaseNugetSmoke"
if [ ! -x "$native_bin" ]; then
  echo "::error::native binary not produced at $native_bin"
  exit 1
fi
out="$("$native_bin" 2>&1)"
echo "native AOT output: $out"
expected='"hi"
42
profile=release'
if [ "$out" != "$expected" ]; then
  echo "::error::manifest+[nuget] native AOT smoke test produced unexpected output: '$out'"
  exit 1
fi
echo "OK: manifest project with a [nuget] dependency built and ran correctly under Native AOT (incl. build_profile=release)." >> "$GITHUB_STEP_SUMMARY"

