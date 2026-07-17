#!/usr/bin/env bash
# Retry a command exactly once iff it was killed by a signal (exit > 128) —
# the SIGBUS-class exit-135 runner kills tracked in #5933, which strike a
# random concurrent self-test step and are unrelated to the code under test
# (observed on comment-only diffs). A genuine test failure (exit <= 128)
# fails immediately with its original exit code, so real regressions are
# never masked; a signal-killed run that passes on retry is by definition
# not a code failure. The retry is loud (::warning::) so residual kill
# frequency stays visible in run logs.
set -uo pipefail
"$@"
rc=$?
if [ "$rc" -gt 128 ]; then
  echo "::warning::step command killed by signal (exit $rc); retrying once (#5933): $*"
  "$@"
  rc=$?
  if [ "$rc" -gt 128 ]; then
    echo "::error::step command killed by signal twice (exit $rc); giving up (#5933): $*"
  fi
fi
exit $rc
