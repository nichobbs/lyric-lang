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
libs="lyric-logging lyric-auth lyric-resilience lyric-otel lyric-db lyric-web lyric-health lyric-grpc"
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
