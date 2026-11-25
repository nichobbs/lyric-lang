#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# h2conn-tests.sh — run the Std.HttpEngine.H2Conn corpora on one target.
#
#   bash scripts/ci/h2conn-tests.sh dotnet|jvm
#
# Runs the server-role corpus (http_h2conn_tests.l) and the client-role corpus
# with its loopback and negative matrix (http_h2conn_client_tests.l) through
# self-test.sh, so a single ci.yml step covers both and the workflow file does
# not grow (see self-test.sh for the size-limit rationale).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

target="${1:-}"
case "$target" in
  dotnet | jvm) ;;
  *)
    echo "::error::h2conn-tests.sh: expected 'dotnet' or 'jvm', got '${target}'" >&2
    exit 2
    ;;
esac

for test_file in http_h2conn_tests.l http_h2conn_client_tests.l; do
  bash scripts/ci/self-test.sh \
    --summary "Std.HttpEngine.H2Conn test ran: ${test_file} (--target ${target})" \
    --target "$target" "lyric-stdlib/tests/${test_file}"
done
