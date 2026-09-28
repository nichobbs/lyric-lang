#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# json-generate-jvm-test.sh — run lyric-stdlib/tests/json_generate_tests.l
# via `lyric run --target jvm` (#7501, #7502).
#
# `json_generate_tests.l` is a `func main`-shaped suite (predates
# `@test_module`), so it runs via `lyric run`, not `scripts/ci/self-test.sh`
# (which always calls `lyric test`). It only ran on `--target dotnet` in CI
# until the JVM backend mangled a dot-named function's classfile method name
# with its declaring type (#7501: two `@generate(Json)` records' `fromJson`
# collided on one bare name and descriptor) and registered a bundled/sibling
# package's own derive-synthesised signatures too (#7502: a nested
# `@generate(Json)` record imported from another package). Kept out of
# ci.yml's own inline `run:` blocks — the file is at its size ceiling, see
# scripts/ci/check-workflow-size.sh.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping json_generate_tests JVM run" >&2
  exit 1
fi

exec "$lyric_bin" run --target jvm lyric-stdlib/tests/json_generate_tests.l
