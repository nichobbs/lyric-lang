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

