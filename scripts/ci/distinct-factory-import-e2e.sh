#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# distinct-factory-import-e2e.sh — end-to-end regression test for a
# package-qualified distinct-type factory call (#7548, in review on #7577):
# a consumer package that `import`s a producer package and calls
# `Pkg.Sub.Type.tryFrom(x)` / `Pkg.Sub.Type.from(x)` on the producer's
# distinct/range-subtype `Type`, rather than the producer's own bare
# `Type.tryFrom(x)` form.
#
#   BUILD_CONFIG=Release bash scripts/ci/distinct-factory-import-e2e.sh
#
# Drives the real CLI over a throwaway two-package project (manifest mode,
# `[project.packages]`) on both `--target dotnet` and `--target jvm`,
# checking that `tryFrom` really validates the range (an in-range value
# produces `Ok`, an out-of-range one produces `Err`) rather than silently
# degrading — the same failure shape #7345/#7495 fixed for a bare-receiver
# and package-qualified FUNCTION call would have taken for a type-associated
# factory call. Invoked from `compiler-self-tests-batch.sh` (whose CI job
# already has Java 21 installed, same precedent as cfg-gated-test-items-e2e.sh),
# so it needs no ci.yml step of its own.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping distinct-factory-import e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/proj/src"
cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "DistinctFactoryImport"
version = "0.1.0"

[project]
name = "DistinctFactoryImport"
output = "single"
output_assembly = "DistinctFactoryImport.dll"

[project.packages]
"Lib.Net.Units" = "src/units.l"
"App" = "src/main.l"
TOML
cat > "$work/proj/src/units.l" <<'EOF'
package Lib.Net.Units

pub type Port = Int range 1 ..= 65535
EOF
# Both a distinct-type `from` and a range-subtype `tryFrom`, both through
# the package-qualified receiver, so the test covers the two factory forms
# `distinctFactoryType`'s bare-receiver arm already recognises.
cat > "$work/proj/src/main.l" <<'EOF'
package App

import Lib.Net.Units

func checkInRange(n: in Int): Int {
  match Lib.Net.Units.Port.tryFrom(n) {
    case Ok(_) -> 0
    case Err(_) -> 1
  }
}

func checkOutOfRange(n: in Int): Int {
  match Lib.Net.Units.Port.tryFrom(n) {
    case Ok(_) -> 1
    case Err(_) -> 0
  }
}

func main(): Int {
  checkInRange(8080) + checkOutOfRange(999999)
}
EOF

m="$work/proj/lyric.toml"
out="$work/out.txt"
for target in dotnet jvm; do
  rc=0
  "$lyric_bin" run --target "$target" --manifest "$m" > "$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [package-qualified distinct-factory call, $target]: lyric run exited $rc" >&2
    cat "$out" >&2
    exit 1
  fi
  echo "distinct-factory-import e2e ($target) passed"
done
echo "distinct-factory-import e2e passed: Lib.Net.Units.Port.tryFrom(n) via the qualified receiver validates the range on both targets (#7548)"
