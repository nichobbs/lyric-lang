#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cli-project-aware-defaults-e2e.sh — project-aware CLI defaults end to end:
# bare `lyric` from a nested subdirectory finds and builds the project,
# `--help` exits 0, an unknown command exits non-zero with a did-you-mean
# suggestion, and bare `lyric` outside a project exits non-zero.
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping CLI e2e smoke test"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
mkdir -p "$work/src/nested"
cat > "$work/lyric.toml" <<'TOML'
[package]
name    = "Demo"
version = "0.1.0"

[project]
name            = "Demo"
output          = "single"
output_assembly = "Demo.dll"

[project.packages]
"Demo" = "src/main.l"
TOML
cat > "$work/src/main.l" <<'LYR'
package Demo
import Std.Core
import Std.Console as Console
pub func main(): Int { Console.println("ok"); 0 }
LYR
# 1. Bare `lyric` from a nested subdir discovers the project and builds it.
( cd "$work/src/nested" && "$bin_abs" )
test -f "$work/bin/Demo.dll" || { echo "expected $work/bin/Demo.dll"; exit 1; }
# 2. --help exits 0.
"$bin_abs" --help >/dev/null
# 3. Unknown command exits non-zero and suggests the nearest command.
if "$bin_abs" buld >"${work}/lyric_buld.out" 2>&1; then
  echo "expected non-zero exit for unknown command"; exit 1
fi
grep -q "did you mean 'build'?" "${work}/lyric_buld.out" || {
  echo "expected did-you-mean suggestion"; cat "${work}/lyric_buld.out"; exit 1; }
# 4. Bare `lyric` outside any project exits non-zero (usage).
empty="$(mktemp -d)"
if ( cd "$empty" && "$bin_abs" ); then
  echo "expected non-zero exit for bare lyric outside a project"; exit 1
fi
echo "CLI project-aware-defaults e2e smoke test passed"
