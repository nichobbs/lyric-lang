#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lyric-init-e2e.sh — `lyric init` end to end: scaffold an app and a library,
# run and build them, refuse an overwrite without --force, apply --force and
# --name without clobbering sources, and reject an invalid name.
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping init e2e"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
cd "$work"
# 1. scaffold an app, run it, build it.
"$bin_abs" init demo
test -f demo/lyric.toml || { echo "lyric.toml not scaffolded"; exit 1; }
test -f demo/src/main.l || { echo "src/main.l not scaffolded"; exit 1; }
test -f demo/.gitignore || { echo ".gitignore not scaffolded"; exit 1; }
grep -q 'package Demo' demo/src/main.l || { echo "package name not capitalised"; exit 1; }
out="$( cd demo && "$bin_abs" run src/main.l )"
echo "run output: $out"
echo "$out" | grep -q "Hello from Demo!" || { echo "scaffolded app did not run"; exit 1; }
( cd demo && "$bin_abs" build )
# 2. --lib scaffolds a buildable library.
"$bin_abs" init mylib --lib
test -f mylib/src/lib.l || { echo "--lib did not scaffold src/lib.l"; exit 1; }
( cd mylib && "$bin_abs" build )
# 3. overwrite refused without --force.
if "$bin_abs" init demo; then echo "expected refusal to overwrite lyric.toml"; exit 1; fi
# 4. --force + --name overwrites lyric.toml but must not clobber src/main.l.
"$bin_abs" init demo --force --name Renamed
grep -q 'name = "Renamed"' demo/lyric.toml || { echo "--name/--force did not apply"; exit 1; }
grep -q 'Hello from Demo!' demo/src/main.l || { echo "--force clobbered src/main.l"; exit 1; }
# 5. bad name rejected.
if "$bin_abs" init weird --name "bad-name"; then echo "expected rejection of invalid name"; exit 1; fi
echo "lyric init e2e passed"
