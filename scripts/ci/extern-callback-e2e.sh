#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# extern-callback-e2e.sh — C callbacks through `@library` bindings (D229).
#
#   bash scripts/ci/extern-callback-e2e.sh [target...]
#
# Builds lyric-compiler/lyric/testdata/lyriccbtest.c into liblyriccbtest.so,
# puts it on the loader path (LD_LIBRARY_PATH for P/Invoke, the JVM's
# libraryLookup and the native binary; LIBRARY_PATH for the native link) and
# runs lyric-compiler/lyric/extern_callback_self_test.l on each target given
# (default: dotnet jvm native).  The JVM run needs a JDK 22 or later `java`
# on PATH (D158).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the C callback e2e" >&2
  exit 1
fi
cc="${CC:-cc}"
command -v "$cc" >/dev/null || cc=clang
command -v "$cc" >/dev/null || { echo "::error::no C compiler (cc or clang) for the C callback fixture" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$cc" -shared -fPIC -O1 -o "$work/liblyriccbtest.so" lyric-compiler/lyric/testdata/lyriccbtest.c -lpthread

export LD_LIBRARY_PATH="$work${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBRARY_PATH="$work${LIBRARY_PATH:+:$LIBRARY_PATH}"

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(dotnet jvm native)
fi
for target in "${targets[@]}"; do
  echo "=== extern_callback_self_test.l (--target $target) ==="
  "$lyric_bin" test --target "$target" lyric-compiler/lyric/extern_callback_self_test.l
done
