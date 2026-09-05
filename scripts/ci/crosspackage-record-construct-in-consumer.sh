#!/usr/bin/env bash
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
work="$(mktemp -d)"
mkdir -p "$work/dep/src" "$work/app/src"
cat > "$work/dep/lyric.toml" <<'TOML'
[package]
name = "rdep"
version = "0.1.0"
[project]
name = "RDep3"
output_assembly = "Lyric.RDep3.dll"
[project.packages]
"RDep3" = "src"
TOML
cat > "$work/dep/src/rdep.l" <<'LYR'
package RDep3
pub record Box { tags: List[Int]; name: String }
pub func describe(b: in Box): String { toString(b.tags.count) + ":" + b.name }
LYR
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "rapp"
version = "0.1.0"
[project]
name = "RApp3"
[project.packages]
"RApp3" = "src"
[dependencies]
rdep = { path = "../dep" }
TOML
cat > "$work/app/src/app.l" <<'LYR'
package RApp3
import RDep3
import Std.Console as Console
func main(): Unit {
  val b = Box(tags = [1, 2, 3, 4], name = "hi")
  Console.println(describe(b))
}
LYR
"$lyric_bin" build --manifest "$work/dep/lyric.toml"
"$lyric_bin" build --manifest "$work/app/lyric.toml"
cp "$work/dep/bin/Lyric.RDep3.dll" "$work/app/bin/"
got="$(cd "$work/app/bin" && dotnet RApp3.dll | tail -1 | tr -d '\r\n')"
echo "consumer printed: '$got'"
if [ "$got" != "4:hi" ]; then
  echo "::error::cross-package record construct-in-consumer returned '$got' (expected '4:hi'); #2592 slice-2 regressed"
  exit 1
fi
echo "cross-package record construct-in-consumer builds the concrete list"

