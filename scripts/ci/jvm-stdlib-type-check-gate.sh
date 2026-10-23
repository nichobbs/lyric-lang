#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# jvm-stdlib-type-check-gate.sh — a `--target jvm` build type-checks the
# stdlib packages it bundles, and a type error in one stops the build
# (#7976, the JVM counterpart of native-stdlib-type-check-gate.sh).
#
#   LYRIC_BIN=<lyric> bash scripts/ci/jvm-stdlib-type-check-gate.sh
#
# The JVM backend compiles the `Std.*` packages a program imports, and their
# `_kernel_jvm/` kernels, from source into every jar.  Their bodies used to be
# type-checked advisorily, so an ill-typed kernel built.  This checks that:
#   1. a program importing every public `Std.*` package builds cleanly, so each
#      of those files (kernels included) type-checks in its bundle context;
#   2. with LYRIC_STD_PATH pointed at a temp copy of the stdlib in which one
#      kernel is ill-typed, a build that reaches that kernel — directly —
#      fails with a non-zero exit,
#      an error[T....] diagnostic naming the package, and no jar.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the JVM stdlib type-check gate" >&2
  exit 1
fi

std_dir="$REPO_ROOT/lyric-stdlib/std"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

package_of() {
  sed -n 's/^package[[:space:]]\{1,\}\([A-Za-z0-9_.]*\).*/\1/p' "$1" | head -n 1
}

write_importer() {
  local out="$1" pkg="$2"
  shift 2
  {
    echo "package $pkg"
    echo
    local f p
    for f in "$@"; do
      p="$(package_of "$f")"
      if [ -n "$p" ]; then
        echo "import $p"
      fi
    done
    echo
    echo "func main(): Int {"
    echo "  0"
    echo "}"
  } > "$out"
}

expect_clean() {
  local label="$1" src="$2" jar="${2%.l}.jar" rc
  set +e
  "$lyric_bin" build --target jvm "$src" -o "$jar" > "$jar.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] || [ ! -f "$jar" ]; then
    echo "::error::$label: the JVM build failed (exit $rc)" >&2
    cat "$jar.log" >&2
    fail=1
  elif grep -q 'error\[' "$jar.log"; then
    echo "::error::$label: the JVM build reported an error" >&2
    cat "$jar.log" >&2
    fail=1
  else
    echo "JVM stdlib type-check gate ($label): OK"
  fi
}

public_files=("$std_dir"/*.l)
write_importer "$work/public.l" JvmStdlibGatePublic "${public_files[@]}"
expect_clean "every public Std package" "$work/public.l"

# A temp copy of the stdlib with one ill-typed kernel.
broken_std="$work/std"
cp -R "$std_dir" "$broken_std"
broken_kernel="$broken_std/_kernel_jvm/random_host.l"
cat >> "$broken_kernel" <<'LYR'

func jvmStdlibGateIllTyped(): Int {
  val b: Bool = 1
  0
}
LYR
broken_pkg="$(package_of "$broken_kernel")"

expect_kernel_rejected() {
  local label="$1" src="$2" jar="${2%.l}.jar" rc bad=0
  set +e
  LYRIC_STD_PATH="$broken_std" "$lyric_bin" build --target jvm "$src" -o "$jar" > "$jar.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "::error::$label: expected a non-zero exit for an ill-typed stdlib kernel, got 0" >&2
    bad=1
  fi
  if ! grep -F "$broken_pkg" "$jar.log" | grep -q 'error\[T0060\]'; then
    echo "::error::$label: expected an error[T0060] diagnostic naming $broken_pkg" >&2
    bad=1
  fi
  if [ -e "$jar" ]; then
    echo "::error::$label: a jar was written at $jar" >&2
    bad=1
  fi
  if [ "$bad" -ne 0 ]; then
    cat "$jar.log" >&2
    fail=1
  else
    echo "JVM stdlib type-check gate ($label): OK"
  fi
}

cat > "$work/direct.l" <<LYR
package JvmStdlibGateDirect

import $broken_pkg

func main(): Int {
  0
}
LYR
expect_kernel_rejected "ill-typed kernel, imported directly" "$work/direct.l"

exit "$fail"
