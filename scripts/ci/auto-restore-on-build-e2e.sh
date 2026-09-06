#!/usr/bin/env bash
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping auto-restore e2e"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
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
[dependencies]
Lib = { path = "../lib" }
TOML
printf 'package App\nimport Std.Core\nimport Std.Console as Console\npub func main(): Int { Console.println("app built"); 0 }\n' > "$work/app/src/main.l"
# A second library, declared as a dependency only in the stale-lock
# case below so the lock written for the first build is out of date.
mkdir -p "$work/lib2/src"
cat > "$work/lib2/lyric.toml" <<'TOML'
[package]
name = "Lib2"
version = "0.1.0"
[project]
name = "Lib2"
output = "single"
output_assembly = "Lib2.dll"
[project.packages]
"Lib2" = "src/lib2.l"
TOML
printf 'package Lib2\nimport Std.Core\npub func two(): Int { 2 }\n' > "$work/lib2/src/lib2.l"
( cd "$work/lib" && "$bin_abs" build )
( cd "$work/lib2" && "$bin_abs" build )
# 1. No lock -> auto-restore writes it and the build succeeds.
( cd "$work/app" && "$bin_abs" build 2>&1 | tee "$work/ar1.out" )
grep -q "resolving dependencies" "$work/ar1.out" || { echo "expected auto-restore message"; exit 1; }
test -f "$work/app/lyric.lock" || { echo "expected lyric.lock to be created"; exit 1; }
# 2. In-sync lock -> no re-restore.
( cd "$work/app" && "$bin_abs" build 2>&1 | tee "$work/ar2.out" )
if grep -q "resolving dependencies" "$work/ar2.out"; then echo "should not re-restore an in-sync lock"; exit 1; fi
# 3. Stale lock -> a dependency added after the lock was written triggers
#    a re-restore (the new dep is absent from lyric.lock).
printf 'Lib2 = { path = "../lib2" }\n' >> "$work/app/lyric.toml"
( cd "$work/app" && "$bin_abs" build 2>&1 | tee "$work/ar3.out" )
grep -q "resolving dependencies" "$work/ar3.out" || { echo "expected re-restore on a stale lock (new dep)"; exit 1; }
# 4. --no-restore after deleting the lock -> no restore, lock not recreated.
#    The build still succeeds (exit 0): both path deps are already built
#    above, so no resolution is needed to compile against them.
rm -f "$work/app/lyric.lock"
( cd "$work/app" && "$bin_abs" build --no-restore ) > "$work/ar4.out" 2>&1; rc=$?
test "$rc" -eq 0 || { echo "--no-restore build should still succeed (exit 0), got $rc"; cat "$work/ar4.out"; exit 1; }
if grep -q "resolving dependencies" "$work/ar4.out"; then echo "--no-restore should skip restore"; exit 1; fi
test ! -f "$work/app/lyric.lock" || { echo "--no-restore should not recreate the lock"; exit 1; }
echo "Auto-restore-on-build e2e passed"

