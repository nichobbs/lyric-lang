#!/usr/bin/env bash
set -uo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping git-dep regression"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
# (0) git dep -> successful resolution against a real local repo (#2126).
#     The parsed git ref (tag/rev/branch) must round-trip to the resolver;
#     it previously read back null and git deps never resolved.
gitc="git -c commit.gpgsign=false -c tag.gpgsign=false -c user.email=t@t -c user.name=t"
mkdir -p "$work/remote"
( cd "$work/remote" && git init -q -b main . && echo seed > f && $gitc add -A && $gitc commit -q -m init --no-gpg-sign && $gitc tag v1.0 )
mkdir -p "$work/ok/src"
cat > "$work/ok/lyric.toml" <<TOML
[package]
name = "Ok"
version = "0.1.0"
[project]
name = "Ok"
output = "single"
output_assembly = "Ok.dll"
[project.packages]
"Ok" = "src/main.l"
[dependencies]
Dep = { git = "file://$work/remote", tag = "v1.0" }
TOML
printf 'package Ok\nimport Std.Core\npub func main(): Int { 0 }\n' > "$work/ok/src/main.l"
( cd "$work/ok" && HOME="$work/home" timeout 120 "$bin_abs" restore ) > "$work/ok.out" 2>&1
okrc=$?
echo "--- ok restore (rc=$okrc) ---"; cat "$work/ok.out"
test "$okrc" -eq 0 || { echo "git-dep restore against a real repo should succeed"; exit 1; }
grep -q "git:file://" "$work/ok/lyric.lock" || { echo "expected a git: lock entry for the resolved dep"; cat "$work/ok/lyric.lock"; exit 1; }
# (a) git dep -> graceful failure, no crash.
mkdir -p "$work/app/src"
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
Bar = { git = "https://example.invalid/bar.git", tag = "v1.0" }
TOML
printf 'package App\nimport Std.Core\npub func main(): Int { 0 }\n' > "$work/app/src/main.l"
# `|| rc=$?` keeps the (expected) non-zero restore from tripping the
# step's `bash -e` errexit before we can inspect the exit code.
rc=0
( cd "$work/app" && timeout 90 "$bin_abs" restore ) > "$work/restore.out" 2>&1 || rc=$?
echo "--- restore output (rc=$rc) ---"; cat "$work/restore.out"
if grep -qiE "Unhandled exception|requires failed|fromInt|NullReferenceException" "$work/restore.out"; then
  echo "git-dep restore crashed instead of failing gracefully"; exit 1
fi
test "$rc" -ne 0 || { echo "git-dep restore of an unreachable repo should exit non-zero"; exit 1; }
# (b) manifest parse error -> real :line:col: location, not garbled chars.
mkdir -p "$work/bad"
printf '[package]\nname = "X"\nversion = "0.1.0"\n[dependencies]\nFoo = { git = \n' > "$work/bad/lyric.toml"
( cd "$work/bad" && "$bin_abs" restore ) > "$work/bad.out" 2>&1 || true
echo "--- manifest-error output ---"; cat "$work/bad.out"
grep -qE 'lyric\.toml:[0-9]+:[0-9]+:' "$work/bad.out" || {
  echo "manifest parse error did not render a numeric :line:col: location"; exit 1; }
echo "Git-dep / manifest-error regression e2e passed"

