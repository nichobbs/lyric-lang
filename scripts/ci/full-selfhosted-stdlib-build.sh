#!/usr/bin/env bash
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/out"
# Post-collapse (D111): the bundle packages self-host-compile into the
# single Lyric.Stdlib.dll; the HTTP/async surface self-host-compiles
# per-package (the #4030 hybrid).  Building both is the "all Std.*
# self-host-compile" guard.
"$lyric_bin" build --manifest lyric-stdlib/lyric.full.toml \
  -o "$work/out/Lyric.Stdlib.dll" --target dotnet --no-restore
if [ ! -f "$work/out/Lyric.Stdlib.dll" ]; then
  echo "::error::single stdlib bundle not produced"
  exit 1
fi
printf 'package HttpAll\nimport Std.Http\nimport Std.HttpServer\nimport Std.Rest\nfunc main(): Unit { }\n' > "$work/http.l"
"$lyric_bin" --internal-perpackage-build "$work/http.l" "$work/httpout" --target dotnet
for dll in Lyric.Stdlib.Http.dll Lyric.Stdlib.Rest.dll Lyric.Stdlib.HttpServer.dll Lyric.Stdlib.Task.dll Lyric.Stdlib.HttpHost.dll; do
  if [ ! -f "$work/httpout/$dll" ]; then
    echo "::error::expected HTTP per-package DLL missing: $dll"
    exit 1
  fi
done
cat > "$work/sorttest.l" <<'LYR'
package SortTest
import Std.Console as Console
import Std.Sort as Sort
func main(): Unit {
  val s = Sort.sortInts([5, 3, 1, 4, 2])
  var acc = ""
  var i = 0
  while i < s.length {
    acc = acc + toString(s[i])
    if i < s.length - 1 { acc = acc + " " }
    i = i + 1
  }
  Console.println(acc)
}
LYR
# Resolution note (#2787): the build below intentionally relies on the
# default stdlib resolution (walking up from the lyric binary to
# lyric-stdlib/std).  LYRIC_STD_PATH points at a stdlib *source*
# directory, so overriding it to $work/out (a DLL output dir) changes
# which artifacts get linked and miscompiles the program — making the
# emitted-DLL set the linked target needs first-class support, tracked
# in #2787.
"$lyric_bin" build "$work/sorttest.l" -o "$work/out/sorttest.dll"
got="$(cd "$work/out" && dotnet sorttest.dll | tr -d '\r\n')"
echo "self-hosted Std.Sort printed: '$got'"
if [ "$got" != "1 2 3 4 5" ]; then
  echo "::error::self-hosted Std.Sort returned '$got', expected '1 2 3 4 5'"
  exit 1
fi
echo "all Std.* packages self-host-compile; self-hosted Std.Sort sorts correctly"

