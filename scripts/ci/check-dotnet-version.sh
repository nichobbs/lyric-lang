#!/usr/bin/env bash
# The .NET version is chosen in bootstrap/global.json. Two other places must
# agree with it and cannot read it: the framework the compiler targets for
# emitted programs (lyric-compiler/lyric/dotnet_target.l) and the ILCompiler
# package of the entry point (Lyric.Cli.Aot.csproj). Fail when either names a
# different .NET major version.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
global_json="$root/bootstrap/global.json"
target_l="$root/lyric-compiler/lyric/dotnet_target.l"
csproj="$root/bootstrap/src/Lyric.Cli.Aot/Lyric.Cli.Aot.csproj"

pinned="$(sed -n 's/.*"version"[^0-9]*\([0-9][0-9]*\)\..*/\1/p' "$global_json" | head -1)"
emitted="$(awk '/^pub func dotnetMajor\(\)/{f=1; next} f && /^[[:space:]]*[0-9]+[[:space:]]*$/{gsub(/[[:space:]]/, ""); print; exit}' "$target_l")"
ilc="$(sed -n 's/.*Include="Microsoft\.DotNet\.ILCompiler" Version="\([0-9][0-9]*\)\..*/\1/p' "$csproj" | head -1)"

rc=0
if [ -z "$pinned" ]; then
  echo "::error file=bootstrap/global.json::no SDK version found"
  exit 1
fi
if [ "$emitted" != "$pinned" ]; then
  echo "::error file=lyric-compiler/lyric/dotnet_target.l::dotnetMajor() is '${emitted}' but bootstrap/global.json pins .NET ${pinned}"
  rc=1
fi
if [ "$ilc" != "$pinned" ]; then
  echo "::error file=bootstrap/src/Lyric.Cli.Aot/Lyric.Cli.Aot.csproj::Microsoft.DotNet.ILCompiler is version '${ilc}.x' but bootstrap/global.json pins .NET ${pinned}"
  rc=1
fi
[ "$rc" -eq 0 ] && echo "check-dotnet-version: .NET ${pinned} in global.json, dotnet_target.l and the ILCompiler reference"
exit "$rc"
