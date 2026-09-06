#!/usr/bin/env bash
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping lyric add e2e"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lib/src" "$work/app/src"
cat > "$work/lib/lyric.toml" <<'TOML'
[package]
name = "Lib"
version = "0.1.0"
[project]
name = "Lib"
output = "single"
output_assembly = "Lib.dll"
[project.packages]
"Lib" = "src/lib.l"
TOML
printf 'package Lib\nimport Std.Core\npub func answer(): Int { 42 }\n' > "$work/lib/src/lib.l"
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "App"
version = "0.1.0"
[project]
name = "App"
output = "single"
output_assembly = "App.dll"
[project.packages]
"App" = "src/main.l"
TOML
printf 'package App\nimport Std.Core\nimport Std.Console as Console\npub func main(): Int { Console.println("ok"); 0 }\n' > "$work/app/src/main.l"
( cd "$work/lib" && "$bin_abs" build )
# registry @version (no restore — offline)
( cd "$work/app" && "$bin_abs" add Foo@1.2.0 --no-restore )
grep -q '^Foo = "1.2.0"$' "$work/app/lyric.toml" || { echo "registry add missing"; cat "$work/app/lyric.toml"; exit 1; }
# idempotent update in place (no duplicate)
( cd "$work/app" && "$bin_abs" add Foo@2.0.0 --no-restore )
[ "$(grep -c '^Foo = ' "$work/app/lyric.toml")" = "1" ] || { echo "re-add duplicated Foo"; exit 1; }
grep -q '^Foo = "2.0.0"$' "$work/app/lyric.toml" || { echo "re-add did not update Foo"; exit 1; }
# nuget table created
( cd "$work/app" && "$bin_abs" add Newtonsoft.Json@13.0.3 --nuget --no-restore )
grep -q '^\[nuget\]$' "$work/app/lyric.toml" || { echo "nuget table not created"; exit 1; }
grep -q '^Newtonsoft.Json = "13.0.3"$' "$work/app/lyric.toml" || { echo "nuget entry missing"; exit 1; }
# git inline-table
( cd "$work/app" && "$bin_abs" add Bar --git https://example.com/bar.git --tag v1.0 --no-restore )
grep -q '^Bar = { git = "https://example.com/bar.git", tag = "v1.0" }$' "$work/app/lyric.toml" || { echo "git entry missing"; cat "$work/app/lyric.toml"; exit 1; }
# restore + build round-trip on a CLEAN manifest: add a path dep that
# resolves offline and let the implicit restore run.  (The asserts
# above use --no-restore, so the bogus registry/nuget/git entries are
# never fetched — restoring them would hit the network.)
mkdir -p "$work/app2/src"
cat > "$work/app2/lyric.toml" <<'TOML'
[package]
name = "App2"
version = "0.1.0"
[project]
name = "App2"
output = "single"
output_assembly = "App2.dll"
[project.packages]
"App2" = "src/main.l"
TOML
printf 'package App2\nimport Std.Core\nimport Std.Console as Console\npub func main(): Int { Console.println("ok"); 0 }\n' > "$work/app2/src/main.l"
( cd "$work/app2" && "$bin_abs" add Lib --path ../lib )
test -f "$work/app2/lyric.lock" || { echo "expected the implicit restore to write lyric.lock"; exit 1; }
( cd "$work/app2" && "$bin_abs" build )
# validation: --tag without --git fails
if ( cd "$work/app" && "$bin_abs" add X --tag v1 --no-restore ); then
  echo "expected failure for --tag without --git"; exit 1
fi
echo "lyric add e2e passed"

