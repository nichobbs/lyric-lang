#!/usr/bin/env bash
# Runs the Std.TcpHost and Std.Http transport tests for one target (D611, D612).
# Usage: stdlib-net-tests.sh dotnet|jvm
# Kept as a script so ci.yml stays under the workflow-size ceiling
# (scripts/ci/check-workflow-size.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
target="${1:?usage: stdlib-net-tests.sh dotnet|jvm}"
tests=(tcp_host_tests tcp_host_tls_tests http_timeout_tests)
if [ "$target" = jvm ]; then
  tests+=(http_server_jvm_tests)
fi
for t in "${tests[@]}"; do
  bash scripts/ci/self-test.sh --target "$target" "lyric-stdlib/tests/$t.l"
done
