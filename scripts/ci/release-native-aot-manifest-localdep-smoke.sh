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
mkdir -p "$dir/dep/src" "$dir/app/src"
cat > "$dir/dep/lyric.toml" <<'TOML'
[package]
name = "releasepathdep"
version = "0.1.0"
[project]
name = "ReleasePathDep"
output_assembly = "Lyric.ReleasePathDep.dll"
[project.packages]
"ReleasePathDep" = "src"
TOML
cat > "$dir/dep/src/dep.l" <<'LYRIC'
package ReleasePathDep
pub func tripleIt(x: Int): Int {
  x * 3
}
LYRIC
cat > "$dir/app/lyric.toml" <<'TOML'
[package]
name = "releasepathsmoke"
version = "0.1.0"
[project]
name = "ReleasePathSmoke"
output = "single"
output_assembly = "ReleasePathSmoke.dll"
[project.packages]
"ReleasePathSmoke" = "src/app.l"
[dependencies]
pathdep = { path = "../dep" }
TOML
# Also asserts build_profile=release on the SAME `buildReleaseProject`
# path as the [nuget] step above; this step's load-bearing assertion is
# `tripleIt(14) == 42`, which only resolves if the dependency's DLL
# (built below, never rebuilt by `resolveManifestDependencies` — see
# its doc comment: "Never triggers a restore") is actually threaded
# into the app's ILC reference list.
cat > "$dir/app/src/app.l" <<'LYRIC'
package ReleasePathSmoke
import Std.Core
import Std.BuildInfo
import ReleasePathDep
pub func main(): Int {
  println(tripleIt(14).toString())
  println("profile=" + buildInfo().profile)
  0
}
LYRIC
(cd "$dir/dep" && "$OLDPWD/$lyric_bin" build)
if [ ! -f "$dir/dep/bin/Lyric.ReleasePathDep.dll" ]; then
  echo "::error::local path dependency did not produce bin/Lyric.ReleasePathDep.dll"
  exit 1
fi
(cd "$dir/app" && "$OLDPWD/$lyric_bin" build --release --aot --rid linux-x64)
native_bin="$dir/app/ReleasePathSmoke"
if [ ! -x "$native_bin" ]; then
  echo "::error::native binary not produced at $native_bin"
  exit 1
fi
out="$("$native_bin" 2>&1)"
echo "native AOT output: $out"
expected='42
profile=release'
if [ "$out" != "$expected" ]; then
  echo "::error::manifest+path-dependency native AOT smoke test produced unexpected output: '$out'"
  exit 1
fi
echo "OK: manifest project with a local path dependency built and ran correctly under Native AOT (resolved.restoredDlls reaches ILC, incl. build_profile=release)." >> "$GITHUB_STEP_SUMMARY"

