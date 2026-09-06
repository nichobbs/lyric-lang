#!/usr/bin/env bash
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
work="$(mktemp -d)"
mkdir -p "$work/udep/src" "$work/uapp/src"
cat > "$work/udep/lyric.toml" <<'TOML'
[package]
name = "udep"
version = "0.1.0"
[project]
name = "UDep"
output_assembly = "Lyric.UDep.dll"
[project.packages]
"UDep" = "src"
TOML
cat > "$work/udep/src/udep.l" <<'LYR'
package UDep
pub union Payload {
  case Items(vals: List[Int])
  case Empty
}
pub func sumPayload(p: in Payload): Int {
  match p {
    case Items(vals) -> {
      var s = 0
      var i = 0
      while i < vals.count { s = s + vals[i]; i = i + 1 }
      s
    }
    case Empty -> 0
  }
}
LYR
cat > "$work/uapp/lyric.toml" <<'TOML'
[package]
name = "uapp"
version = "0.1.0"
[project]
name = "UApp"
[project.packages]
"UApp" = "src"
[dependencies]
udep = { path = "../udep" }
TOML
cat > "$work/uapp/src/uapp.l" <<'LYR'
package UApp
import UDep
import Std.Console as Console
func main(): Unit {
  val p = Items(vals = [10, 20, 30])
  Console.println(toString(sumPayload(p)))
}
LYR
"$lyric_bin" build --manifest "$work/udep/lyric.toml"
"$lyric_bin" build --manifest "$work/uapp/lyric.toml"
cp "$work/udep/bin/Lyric.UDep.dll" "$work/uapp/bin/"
got="$(cd "$work/uapp/bin" && dotnet UApp.dll | tail -1 | tr -d '\r\n')"
echo "cross-package union consumer printed: '$got'"
if [ "$got" != "60" ]; then
  echo "::error::cross-package union construct+match returned '$got', expected '60' (#2897)"
  exit 1
fi
echo "cross-package union construct+match with List[Int] payload works (#2897)"

