#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# bench-vec3-alloc.sh — Vec3 arithmetic does not allocate on native (docs/67
# G1 exit criterion).
#
#   bash scripts/ci/bench-vec3-alloc.sh
#
# Runs `lyric bench --target native benchmarks/bench_vec3.l` and requires a
# result line for every `@bench` function in the file, each reporting
# `alloc=0B/run`.  A value record (D157), a derived `+`/`-` (D155) or an inline
# `array[N, T]` (D167) that starts allocating on the heap fails this check.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the Vec3 allocation bench" >&2
  exit 1
fi

src=benchmarks/bench_vec3.l
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if ! "$lyric_bin" bench --target native "$src" --runs 5 --warmup 1 >"$work/bench.log" 2>&1; then
  echo "::error::lyric bench --target native $src failed" >&2
  cat "$work/bench.log" >&2
  exit 1
fi
cat "$work/bench.log"

mapfile -t benches < <(grep -A1 '^@bench$' "$src" | sed -n 's/^pub func \([A-Za-z0-9_]*\)(.*/\1/p')
if [[ ${#benches[@]} -eq 0 ]]; then
  echo "::error::no @bench functions found in $src" >&2
  exit 1
fi

fail=0
for b in "${benches[@]}"; do
  line="$(grep -E "^${b}[[:space:]]" "$work/bench.log" || true)"
  if [[ -z "$line" ]]; then
    echo "::error::no result line for $b" >&2
    fail=1
  elif ! grep -q 'alloc=0B/run' <<<"$line"; then
    echo "::error::$b allocates on --target native: $line" >&2
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "Vec3 benches (${#benches[@]}) allocate nothing on --target native"
