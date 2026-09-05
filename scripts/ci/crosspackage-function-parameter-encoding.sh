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
name = "fdep"
version = "0.1.0"
[project]
name = "FDep"
output_assembly = "Lyric.FDep.dll"
[project.packages]
"FDep" = "src"
TOML
cat > "$work/dep/src/fdep.l" <<'LYR'
package FDep
pub record Err { field: String; msg: String }
pub func mkErr(): Err { Err(field = "name", msg = "required") }
pub func describe(e: in Err): String { e.field + ":" + e.msg }
pub func combine(a: in Err, b: in Err): String { describe(a) + "|" + describe(b) }
LYR
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "fapp"
version = "0.1.0"
[project]
name = "FApp"
[project.packages]
"FApp" = "src"
[dependencies]
fdep = { path = "../dep" }
TOML
cat > "$work/app/src/app.l" <<'LYR'
package FApp
import FDep
import Std.Console as Console
func main(): Unit {
  val a = mkErr()
  val b = mkErr()
  Console.println(describe(a) + " " + combine(a, b))
}
LYR
"$lyric_bin" build --manifest "$work/dep/lyric.toml"
"$lyric_bin" build --manifest "$work/app/lyric.toml"
# Stage the local-path dependency DLL beside the consumer so it loads
# at run time (the Err type + functions live in Lyric.FDep.dll).
cp "$work/dep/bin/Lyric.FDep.dll" "$work/app/bin/"
got="$(cd "$work/app/bin" && dotnet FApp.dll | tail -1 | tr -d '\r\n')"
echo "consumer printed: '$got'"
if [ "$got" != "name:required name:required|name:required" ]; then
  echo "::error::cross-package function param call returned '$got', expected 'name:required name:required|name:required'"
  exit 1
fi
echo "cross-package non-generic function reference-typed params bind concretely"

