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
name = "recdep"
version = "0.1.0"
[project]
name = "RecDep"
output_assembly = "Lyric.RecDep.dll"
[project.packages]
"RecDep" = "src"
TOML
cat > "$work/dep/src/recdep.l" <<'LYR'
package RecDep
pub record Item { v: Int }
pub record Rec { ints: List[Int]; items: List[Item]; name: String }
pub func mkRec(): Rec { Rec(ints = [1, 2, 3], items = [Item(v = 9)], name = "hi") }
LYR
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "recapp"
version = "0.1.0"
[project]
name = "RecApp"
[project.packages]
"RecApp" = "src"
[dependencies]
recdep = { path = "../dep" }
TOML
cat > "$work/app/src/app.l" <<'LYR'
package RecApp
import RecDep
import Std.Console as Console
func main(): Unit {
  val r = mkRec()
  Console.println(toString(r.ints.count) + " " + toString(r.items.count) + " " + r.name)
}
LYR
"$lyric_bin" build --manifest "$work/dep/lyric.toml"
"$lyric_bin" build --manifest "$work/app/lyric.toml"
# Stage the local-path dependency DLL beside the consumer so it loads
# at run time (the Rec type lives in Lyric.RecDep.dll).
cp "$work/dep/bin/Lyric.RecDep.dll" "$work/app/bin/"
got="$(cd "$work/app/bin" && dotnet RecApp.dll | tail -1 | tr -d '\r\n')"
echo "consumer printed: '$got'"
if [ "$got" != "3 1 hi" ]; then
  echo "::error::cross-package record field read returned '$got', expected '3 1 hi'"
  exit 1
fi
echo "cross-package non-generic record field binds concretely"

