#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-multi-package-examples.sh — builds the ecosystem libraries the
# multi-package examples depend on, runs `lyric test` on each example, and
# checks examples/contracts-gating-test on both targets (#7701).
# ---------------------------------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::warning::AOT binary not found; skipping example tests"
  exit 0
fi
# Build dependency libraries. lyric-grpc's dotnet kernel (Grpc.Net.Client,
# Grpc.AspNetCore, System.Threading.RateLimiting) and lyric-db's
# (Npgsql, Microsoft.Data.Sqlite) both have mandatory NuGet deps
# whose extern types/ctors resolve from package metadata at compile
# time -- restore first, like the dedicated "Run tests (grpc)" /
# "Run tests (db)" ecosystem-tests steps do. Reproduced empirically:
# a `lyric build` against a clean (no obj/) checkout of either
# throws the same "cannot be resolved to any indexed reference
# assembly" FFI exception without restore first (#6582).
nuget_libs="lyric-db lyric-grpc"
libs="lyric-logging lyric-auth lyric-resilience lyric-otel lyric-db lyric-ws lyric-web lyric-health lyric-grpc"
for lib in $libs; do
  case " $nuget_libs " in
    *" $lib "*)
      echo "=== restore dependency $lib ==="
      "$lyric_bin" restore --manifest "$lib/lyric.toml" > /tmp/"$lib".restore.log 2>&1 || { tail -20 /tmp/"$lib".restore.log; exit 1; }
      ;;
  esac
  echo "=== build dependency $lib ==="
  "$lyric_bin" build --manifest "$lib/lyric.toml" > /tmp/"$lib".log 2>&1 || { tail -20 /tmp/"$lib".log; exit 1; }
done
# Test each example
for ex in rbac ledger jobqueue product-catalog; do
  echo "=== test examples/$ex ==="
  "$lyric_bin" test --manifest "examples/$ex/lyric.toml" > /tmp/"$ex".test.log 2>&1 \
    && echo "PASS" || { echo "FAIL"; cat /tmp/"$ex".test.log; exit 1; }
done
# Build contracts-gating-test (verifies aspect-composed contracts respect [contracts] enabled = false)
# Test on both dotnet and jvm targets to ensure parity of contract gating across backends (#7701).
echo "=== build examples/contracts-gating-test --target dotnet ==="
"$lyric_bin" build --manifest "examples/contracts-gating-test/lyric.toml" --target dotnet > /tmp/contracts-gating-test.log 2>&1 \
  && { echo "PASS: contracts disabled, function with contract-violating behavior compiles"; dotnet "examples/contracts-gating-test/bin/contracts-gating-test.dll" > /tmp/contracts-gating-test.run.log 2>&1 && echo "PASS: function executes without assertion failure"; } \
  || { echo "FAIL"; cat /tmp/contracts-gating-test.log; cat /tmp/contracts-gating-test.run.log 2>/dev/null; exit 1; }
echo "=== build examples/contracts-gating-test --target jvm ==="
"$lyric_bin" build --manifest "examples/contracts-gating-test/lyric.toml" --target jvm > /tmp/contracts-gating-test-jvm.log 2>&1 \
  && { echo "PASS: contracts disabled (JVM), function with contract-violating behavior compiles"; java -jar "examples/contracts-gating-test/bin/contracts-gating-test.jar" > /tmp/contracts-gating-test-jvm.run.log 2>&1 && echo "PASS: function executes without assertion failure (JVM)"; } \
  || { echo "FAIL"; cat /tmp/contracts-gating-test-jvm.log; cat /tmp/contracts-gating-test-jvm.run.log 2>/dev/null; exit 1; }
# #7508 cross-package case (#7675): an imported package's newList/mapGet
# overrides the builtin intrinsic of the same name (native: native-target-smoke-test.sh).
for target in dotnet jvm; do
  bash scripts/ci/builtin-name-override-test.sh "$lyric_bin" "$target"
done
# A generic call passed to another generic is specialised from the outer
# call's expected type when it is imported.
for target in dotnet jvm; do
  bash scripts/ci/nested-generic-expected-test.sh "$lyric_bin" "$target"
done
# examples/agent/basics.l is the canonical-idioms reference agents copy from
# (#7606): it must keep compiling and printing the same output on both targets.
expected_basics=$'double 5 = 10\norder total: 1500 cents\nactive: amy, zoe\nrange: 1 to 9'
for target in dotnet jvm; do
  echo "=== run examples/agent/basics.l --target $target ==="
  got="$("$lyric_bin" run --target "$target" examples/agent/basics.l 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS' | grep -v '^built ')" || true
  if [ "$got" != "$expected_basics" ]; then
    echo "FAIL: unexpected output from examples/agent/basics.l --target $target:"
    echo "$got"
    exit 1
  fi
  echo "PASS"
done
# The other examples/agent files are runnable references too (#8472): each must
# keep compiling and printing the same output on both targets, and tests.l must
# keep passing under `lyric test`.
run_agent_example() {
  local file="$1" expected="$2" target="$3"
  echo "=== run examples/agent/$file --target $target ==="
  local got
  got="$(LYRIC_CONFIG_EXAMPLES_CONFIGANDASPECTS_DB_URL=postgres://db "$lyric_bin" run --target "$target" "examples/agent/$file" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS' | grep -v '^built ' | grep -v 'warning\[W0002\]')" || true
  if [ "$got" != "$expected" ]; then
    echo "FAIL: unexpected output from examples/agent/$file --target $target:"
    echo "$got"
    exit 1
  fi
  echo "PASS"
}
expected_contracts=$'divide: 3\ntransferred 200 from 1 to 2\noverdrawn\nincr: 42\nkept 3\ndoubled 3\nwallet 250\nwallet error: balance out of range'
expected_di=$'clock: 1000\ncreate: created amy\nagain: conflict: user already exists\nsequential: profile-4 40\nparallel: profile-5 50\ntokens left: 2\nwithLog: 42 start,cleanup'
expected_config=$'server: 0.0.0.0:8080\nconnecting to postgres://db with pool 10\ngetUser: user-7 [auth: check handleGetUser, log: enter handleGetUser, log: exit handleGetUser]\nhealth: ok []\nmetrics: metrics [auth: check handleMetrics]'
for target in dotnet jvm; do
  run_agent_example contracts.l "$expected_contracts" "$target"
  run_agent_example di-and-async.l "$expected_di" "$target"
  run_agent_example config-and-aspects.l "$expected_config" "$target"
  echo "=== test examples/agent/tests.l --target $target ==="
  "$lyric_bin" test --target "$target" examples/agent/tests.l > /tmp/agent-tests-"$target".log 2>&1 \
    && echo "PASS" || { echo "FAIL"; cat /tmp/agent-tests-"$target".log; exit 1; }
done
