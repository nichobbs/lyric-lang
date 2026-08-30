#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-env-args-ordering.sh — Std.Environment.args() class-init
# ordering-hazard check on JVM (#6587).
#
# Builds lyric-compiler/jvm/env_args_ordering_jvm_main.l, whose
# module-level `val` calls Std.Environment.args() (forcing that call
# during the entry class's own `<clinit>`, strictly before the
# entry-point wrapper's `putstatic __LyricJvmRuntime.commandLineArgs`
# runs), and asserts the process crashes with the guarded diagnostic
# naming the ordering hazard rather than main() running or a bare
# NullPointerException.
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
  echo "::error::AOT binary not found at $lyric_bin; skipping Std.Environment.args() ordering-hazard JVM check" >&2
  exit 1
fi

work="$(mktemp -d)"
"$lyric_bin" build lyric-compiler/jvm/env_args_ordering_jvm_main.l --target jvm -o "$work/envargsordering.jar"

set +e
out="$(java -jar "$work/envargsordering.jar" 2>&1)"
code=$?
set -e
echo "$out"

if [ "$code" -eq 0 ]; then
  echo "::error::env_args_ordering_jvm_main exited 0 (#6587 guard did not fire; main() may have run with a null/default argv)" >&2
  exit 1
fi

grep -q "FAIL: reached main()" <<< "$out" && {
  echo "::error::main() ran despite the class-init-time argv read (#6587 guard did not fire)" >&2
  exit 1
}
grep -q "was called before the JVM entry-point wrapper populated its argv holder" <<< "$out" || {
  echo "::error::expected diagnostic naming the #6587 ordering hazard was not in the output (bare NullPointerException regression?)" >&2
  exit 1
}

echo "OK: env_args_ordering_jvm_main crashed with the #6587 diagnostic, main() never reached."
