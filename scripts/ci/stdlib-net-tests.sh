#!/usr/bin/env bash
# Runs the Std.TcpHost and Std.Http transport tests, the Std.HttpServerHost seam tests
# (D786) and, on dotnet, the stop contract of the shared server driver (D788), for one target.
# Usage: stdlib-net-tests.sh dotnet|jvm
# Kept as a script so ci.yml stays under the workflow-size ceiling
# (scripts/ci/check-workflow-size.sh).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
target="${1:?usage: stdlib-net-tests.sh dotnet|jvm}"
tests=(tcp_host_tests tcp_host_tls_tests http_timeout_tests http_server_host_tests)
if [ "$target" = jvm ]; then
  tests+=(http_server_jvm_tests)
fi
# The shared driver is read only by the dotnet loader until the JVM and native
# kernels are deleted (docs/73 S4, S5); those two targets run it from then on.
if [ "$target" = dotnet ]; then
  tests+=(http_server_stop_tests)
fi
for t in "${tests[@]}"; do
  bash scripts/ci/self-test.sh --target "$target" "lyric-stdlib/tests/$t.l"
done
