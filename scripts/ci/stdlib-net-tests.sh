#!/usr/bin/env bash
# Runs the Std.TcpHost and Std.Http transport tests, the Std.HttpServerHost seam tests
# (D786) and the shared Std.HttpServer driver's stop contract (D788) for one target.
# On the JVM it also runs the target-neutral server suite (http_server_tests.l, which
# dotnet runs from its own step) and the curl --http2 smoke against the JVM listener
# (docs/73 S4, D789).
# Usage: stdlib-net-tests.sh dotnet|jvm
# Kept as a script so ci.yml stays under the workflow-size ceiling
# (scripts/ci/check-workflow-size.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
target="${1:?usage: stdlib-net-tests.sh dotnet|jvm}"
tests=(tcp_host_tests tcp_host_tls_tests http_timeout_tests http_server_host_tests http_server_stop_tests)
if [ "$target" = jvm ]; then
  tests+=(http_server_tests)
fi
for t in "${tests[@]}"; do
  bash scripts/ci/self-test.sh --target "$target" "lyric-stdlib/tests/$t.l"
done
if [ "$target" = jvm ]; then
  bash scripts/ci/h2-smoke.sh jvm
fi
