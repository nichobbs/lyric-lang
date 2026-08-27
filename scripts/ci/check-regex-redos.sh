#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-regex-redos.sh — Std.Regex ReDoS-timeout enforcement on JVM
# (#330/#1103, throughput/cap follow-up #6576).
#
# Builds a program that races a catastrophic-backtracking pattern against
# adversarial input through Std.Regex.tryIsMatch and asserts Err(TimedOut)
# within the compiled-in deadline, proving the std/_kernel_jvm/regex_host.l
# daemon-thread-race shim actually enforces the timeout it accepts.
#
# Extracted out of ci.yml to keep the workflow file under its size
# ceiling — see scripts/ci/self-test.sh's header for the full story.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping Std.Regex ReDoS-timeout JVM check" >&2
  exit 1
fi

work="$(mktemp -d)"
"$lyric_bin" build lyric-compiler/jvm/regex_redos_jvm_main.l --target jvm -o "$work/regexredos.jar"

# Generous wall-clock cap: the compiled-in deadline is 1.5s: a 20s timeout
# catches "shim missing -> hangs" without flaking on a loaded CI runner.
# set +e/set -e around the capture: the program returns non-zero on
# failure, and a failing command substitution under `set -e` would abort
# before the echo/grep diagnostics below ever ran.
set +e
out="$(timeout 20 java -jar "$work/regexredos.jar")"
code=$?
set -e
echo "$out"

if [ "$code" -ne 0 ]; then
  echo "::error::regex_redos_jvm_main exited $code (#1103 daemon-thread shim not enforcing the deadline, or a hang past the 20s cap)" >&2
  exit 1
fi
grep -q "^ok:" <<< "$out" || {
  echo "::error::regex_redos_jvm_main did not report ok (#1103 daemon-thread shim not enforcing the deadline)" >&2
  exit 1
}
