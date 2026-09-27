#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cfg-gated-test-items-e2e.sh — end-to-end regression test for `@cfg` on
# individual `test`/`property` items under `lyric test` (#7481).
#
#   BUILD_CONFIG=Release bash scripts/ci/cfg-gated-test-items-e2e.sh
#
# `Lyric.TestSynth` builds the runner's `main` before `Lyric.Cfg` erasure
# runs.  An erased test used to stay in `main` as a call to a function that no
# longer existed (T0020 "unknown name '__lyric_test_N'") and was counted in the
# TAP plan.  This drives the real CLI over a throwaway project (manifest mode,
# `[features]` + `--features`) and a manifest-less single file, on both
# `--target dotnet` and `--target jvm`, and checks the exact TAP plan and which
# tests ran.  Invoked from `compiler-self-tests-batch.sh` (whose CI job already
# has Java 21 installed), so it needs no ci.yml step of its own.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping @cfg test-item e2e" >&2
  exit 1
fi

# Outside the repository, so single-file mode discovers no manifest.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/proj/src" "$work/proj/tests" "$work/single"
cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "CfgTestItems"
version = "0.1.0"

[project]
name = "CfgTestItems"
output = "single"
output_assembly = "CfgTestItems.dll"

[project.packages]
"CfgTestItems" = "src/lib.l"

[project.tests]
"CfgTestItems.Tests" = "tests/cfg_tests.l"

[features]
default = []
extra = []
TOML
cat > "$work/proj/src/lib.l" <<'EOF'
package CfgTestItems

pub func base(): Int {
  1
}

@cfg(feature = "extra")
pub func extraOnly(): Int {
  7
}
EOF
# `extra only` references `extraOnly`, which only exists under `extra`: the
# test must be erased (not merely skipped) when the feature is inactive.
cat > "$work/proj/tests/cfg_tests.l" <<'EOF'
@test_module
package CfgTestItems.Tests

import Std.Testing
import CfgTestItems

test "ungated" {
  assertEqualInt(base(), 1, "base")
}

@cfg(feature = "extra")
test "extra only" {
  assertEqualInt(extraOnly(), 7, "extraOnly")
}

@cfg(target = "dotnet")
test "dotnet only" {
  assertTrue(true, "dotnet")
}

@cfg(target = "jvm")
test "jvm only" {
  assertTrue(true, "jvm")
}
EOF
cat > "$work/single/gated_tests.l" <<'EOF'
@test_module
package GatedSingle

import Std.Testing

test "ungated" {
  assertTrue(true, "x")
}

@cfg(feature = "never_active")
test "never active" {
  val x: NoSuchType = 0
  assertTrue(false, "ran a test gated by an inactive feature")
}

@cfg(target = "dotnet")
test "dotnet only" {
  assertTrue(true, "d")
}

@cfg(target = "jvm")
test "jvm only" {
  assertTrue(true, "j")
}

@cfg(feature = "never_active")
property "never active property" forall (n: Int) {
  assertTrue(false, "ran a property gated by an inactive feature")
}
EOF

failures=0
# run_case <label> <expected plan> <comma-separated titles that must run>
#          <comma-separated titles that must be absent> -- <lyric test args...>
run_case() {
  local label="$1" plan="$2" present="$3" absent="$4"
  shift 5
  local out="$work/out.txt" rc=0
  "$lyric_bin" test "$@" > "$out" 2>&1 || rc=$?
  local ok=1
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: lyric test exited $rc"; ok=0
  fi
  if ! grep -qx "$plan" "$out"; then
    echo "FAIL [$label]: expected TAP plan '$plan'"; ok=0
  fi
  if grep -q "T0020" "$out"; then
    echo "FAIL [$label]: runner referenced an erased test function (T0020)"; ok=0
  fi
  local t
  IFS=',' read -ra want <<< "$present"
  for t in "${want[@]}"; do
    [ -z "$t" ] && continue
    if ! grep -qE "^ok [0-9]+ - $t\$" "$out"; then
      echo "FAIL [$label]: expected '$t' to run and pass"; ok=0
    fi
  done
  IFS=',' read -ra gone <<< "$absent"
  for t in "${gone[@]}"; do
    [ -z "$t" ] && continue
    if grep -q -- "- $t" "$out"; then
      echo "FAIL [$label]: gated '$t' should be absent from the run"; ok=0
    fi
  done
  if [ "$ok" -eq 1 ]; then
    echo "ok   [$label]"
  else
    echo "---- output [$label] ----"; cat "$out"; echo "----"
    failures=$((failures + 1))
  fi
}

m="$work/proj/lyric.toml"
run_case "manifest dotnet, no features" "1..2" "ungated,dotnet only" "extra only,jvm only" -- \
  --manifest "$m"
run_case "manifest dotnet, --features extra" "1..3" "ungated,extra only,dotnet only" "jvm only" -- \
  --manifest "$m" --features extra
run_case "manifest jvm, no features" "1..2" "ungated,jvm only" "extra only,dotnet only" -- \
  --manifest "$m" --target jvm
run_case "manifest jvm, --features extra" "1..3" "ungated,extra only,jvm only" "dotnet only" -- \
  --manifest "$m" --target jvm --features extra

s="$work/single/gated_tests.l"
run_case "single-file dotnet" "1..2" "ungated,dotnet only" "never active,jvm only" -- "$s"
run_case "single-file jvm" "1..2" "ungated,jvm only" "never active,dotnet only" -- "$s" --target jvm
run_case "single-file dotnet --properties" "1..2" "ungated,dotnet only" "never active,jvm only" -- \
  "$s" --properties
run_case "single-file jvm --properties" "1..2" "ungated,jvm only" "never active,dotnet only" -- \
  "$s" --target jvm --properties

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures @cfg test-item e2e case(s) failed (#7481)" >&2
  exit 1
fi
echo "@cfg-gated test items e2e passed (manifest + single-file, dotnet + jvm)"
