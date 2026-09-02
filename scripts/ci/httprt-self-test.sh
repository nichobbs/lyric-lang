#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# httprt-self-test.sh — run one live-HTTP round-trip self-test through the
# AOT `lyric` binary, against a merged stdlib+compiler LYRIC_STDLIB_BIN dir.
#
#   bash scripts/ci/httprt-self-test.sh <label> <self-test-file.l>
#
# e.g.
#
#   bash scripts/ci/httprt-self-test.sh "Std.Http round-trip" \
#     lyric-compiler/lyric/http_roundtrip_self_test.l
#
# Shared by the Std.Http and Std.Rest round-trip CI steps (docs/61 §5.1):
# both build a `.bootstrap/httprt-lib` override directory (the stage-1
# compiler DLLs — the test module imports Lyric.Emitter — overlaid with the
# "Build full stdlib" step's `lyric-stdlib/bin/Lyric.Stdlib*.dll`, plus the
# self-hosted-emitted `selfhosted/` compiler bundle staged alongside the AOT
# binary, without which `lyric test`'s compiler-DLL discovery falls back to
# the F#-emitted stage-1 DLLs whose arity convention no longer matches the
# self-hosted emitter, D111) so the round trip executes stdlib machine code
# emitted by the compiler under test, not the seed-built stage-1 stdlib.
# See scripts/ci/self-test.sh's header for why this lives in a script
# instead of ci.yml's `run:` block (the workflow-file size ceiling, #6387).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

if [[ $# -ne 2 ]]; then
  echo "::error::httprt-self-test.sh: expected <label> <self-test-file.l>" >&2
  exit 2
fi
label="$1"
test_file="$2"

if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping $label self-test" >&2
  exit 1
fi

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping $label self-test" >&2
  exit 1
fi

if [ ! -f lyric-stdlib/bin/Lyric.Stdlib.dll ]; then
  echo "::error::lyric-stdlib/bin/Lyric.Stdlib.dll missing — the 'Build full stdlib' step must run before this one" >&2
  exit 1
fi

rm -rf .bootstrap/httprt-lib
mkdir -p .bootstrap/httprt-lib
cp .bootstrap/stage1/*.dll .bootstrap/httprt-lib/
cp lyric-stdlib/bin/Lyric.Stdlib*.dll .bootstrap/httprt-lib/
if [ -d "$(dirname "$lyric_bin")/selfhosted" ]; then
  cp -r "$(dirname "$lyric_bin")/selfhosted" .bootstrap/httprt-lib/selfhosted
fi

LYRIC_STDLIB_BIN="$PWD/.bootstrap/httprt-lib" "$lyric_bin" test --target dotnet "$test_file"
