#!/usr/bin/env bash
set -euo pipefail
publish_dir="$(mktemp -d)"
dotnet publish bootstrap/src/Lyric.Cli.Aot -c Release -r linux-x64 -o "$publish_dir"
native_cli="$publish_dir/lyric"
if [ ! -x "$native_cli" ]; then
  echo "::error::native lyric CLI not produced at $native_cli"
  exit 1
fi
file "$native_cli" | grep -q ELF || { echo "::error::published lyric CLI is not a native ELF"; exit 1; }
"$native_cli" --version
dir="$(mktemp -d)"
cat > "$dir/hello.l" <<'LYRIC'
package Hello
import Std.Core
func main(): Int {
  println("hello-native-cli")
  0
}
LYRIC
"$native_cli" build "$dir/hello.l" -o "$dir/bin/Hello.dll"
cp bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/Lyric.Stdlib*.dll "$dir/bin/"
out="$(cd "$dir/bin" && dotnet exec Hello.dll)"
echo "native CLI build output: $out"
if [ "$out" != "hello-native-cli" ]; then
  echo "::error::lyric build through the native CLI produced unexpected output: '$out'"
  exit 1
fi

# Release-layout regression guard for #7619 (docs/progress/2026-09-28-
# stdlib-bundle-reconstruction-keeps-imports.md): a genuine "installed,
# no lyric-stdlib/std source tree reachable" layout falls back to
# rebuilding every stdlib package from Lyric.Stdlib.dll's embedded
# contract metadata (stdlibSourcesFromCompiledBundle), which used to
# render no `import` lines and hid List/newList behind Std.Collections'
# whole import of Std.CollectionsHost (T0010/T0020, #7617). The checks
# above never hit that path: $native_cli was published outside the repo,
# but the build ran with cwd still at the repo checkout, so
# findStdlibSources' CWD fallback (lyric-compiler/lyric/emitter.l) kept
# finding the real lyric-stdlib/std/ source tree. Force the fallback for
# real: cd into an isolated tree containing only the published native
# binary and the compiled Lyric.Stdlib*.dll bundle (no lyric-stdlib/std
# anywhere on the walk-up path, no $LYRIC_STD_PATH), then build a program
# that reaches List only through Std.Collections' whole import.
release_dir="$(mktemp -d)"
cp "$native_cli" "$release_dir/lyric"
cp bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/Lyric.Stdlib*.dll "$release_dir/"
cat > "$release_dir/list_via_collections.l" <<'LYRIC'
package ListViaCollections
import Std.Collections
func main(): Int {
  val xs: List[Int] = newList()
  xs.add(42)
  println(toString(xs[0]))
  0
}
LYRIC
(
  cd "$release_dir"
  unset LYRIC_STD_PATH
  ./lyric build list_via_collections.l -o ListViaCollections.dll
  list_out="$(dotnet exec ListViaCollections.dll)"
  echo "release-layout List/Std.Collections output: $list_out"
  if [ "$list_out" != "42" ]; then
    echo "::error::#7619 regression: release-layout (no lyric-stdlib/std reachable) build of a Std.Collections-only List program returned '$list_out', expected '42'"
    exit 1
  fi
)
echo "OK: release-layout (no lyric-stdlib/std source tree reachable) stdlib-bundle rebuild kept Std.Collections' import of Std.CollectionsHost; List/newList resolved (#7619 regression guard)." >> "$GITHUB_STEP_SUMMARY"

# Restored-dependency build through the native binary (#3201).  A
# local-path `[dependencies]` entry threads the producer DLL as a
# restored dep; the consumer build must read the producer's embedded
# `Lyric.Contract` metadata to inline its `pub val ANSWER`.  Under
# Native AOT this previously threw `PlatformNotSupportedException`
# (no IL loader for `Assembly.Load(byte[])`); the metadata-direct
# reader makes it pure byte reading, so it now works.
work="$(mktemp -d)"
mkdir -p "$work/constdep/src" "$work/app/src"
cat > "$work/constdep/lyric.toml" <<'TOML'
[package]
name = "constdep"
version = "0.1.0"
[project]
name = "ConstDep"
output_assembly = "Lyric.ConstDep.dll"
[project.packages]
"ConstDep" = "src"
TOML
cat > "$work/constdep/src/constdep.l" <<'LYR'
package ConstDep
pub val ANSWER: Int = 0x002A
LYR
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "app"
version = "0.1.0"
[project]
name = "App"
[project.packages]
"App" = "src"
[dependencies]
constdep = { path = "../constdep" }
TOML
cat > "$work/app/src/app.l" <<'LYR'
package App
import ConstDep
import Std.Console as Console
func main(): Unit {
  Console.println(toString(ANSWER))
}
LYR
"$native_cli" build --manifest "$work/constdep/lyric.toml"
"$native_cli" build --manifest "$work/app/lyric.toml"
cp bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/Lyric.Stdlib*.dll "$work/app/bin/"
dep_out="$(cd "$work/app/bin" && dotnet exec App.dll | tr -d '\r\n')"
echo "restored-dep consumer printed: '$dep_out'"
if [ "$dep_out" != "42" ]; then
  echo "::error::restored-dep build through the native CLI returned '$dep_out', expected '42' (metadata-direct contract read regressed under AOT)"
  exit 1
fi

size_kb=$(du -k "$native_cli" | cut -f1)
echo "OK: Native AOT lyric CLI published (${size_kb} KB), built+ran an example and a restored-dependency build end-to-end." >> "$GITHUB_STEP_SUMMARY"

