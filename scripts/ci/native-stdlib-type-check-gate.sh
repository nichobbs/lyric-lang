#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-stdlib-type-check-gate.sh — a `--target native` build type-checks
# the stdlib packages it bundles, and a type error in one stops the build
# (#7933).
#
#   LYRIC_BIN=<lyric> LYRIC_RT_PATH=<lyric_rt.a> bash scripts/ci/native-stdlib-type-check-gate.sh
#
# Native compiles the `Std.*` packages from source into every binary.  Their
# bodies used to reach codegen without a type check, so an ill-typed kernel
# built and ran.  This checks that:
#   1. a program importing every `_kernel_native/` package, and one importing
#      every public `Std.*` package, build cleanly: each of those files
#      type-checks in its native bundle context;
#   2. with LYRIC_STD_PATH pointed at a temp copy of the stdlib in which one
#      kernel is ill-typed, a build that reaches that kernel — directly, or
#      only through another package's imports — fails with a non-zero exit,
#      an error[T....] diagnostic naming the kernel's file, and no binary.
# Invoked from `native-target-smoke-test.sh`, which builds the runtime it
# links against.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the native stdlib type-check gate" >&2
  exit 1
fi

std_dir="$REPO_ROOT/lyric-stdlib/std"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

package_of() {
  sed -n 's/^package[[:space:]]\{1,\}\([A-Za-z0-9_.]*\).*/\1/p' "$1" | head -n 1
}

# write_importer <out.l> <package> <file>...: a program importing the
# package of every file given.
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

# expect_clean <label> <source.l>
expect_clean() {
  local label="$1" src="$2" bin="${2%.l}" rc
  set +e
  "$lyric_bin" build --target native "$src" -o "$bin" > "$bin.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] || [ ! -x "$bin" ]; then
    echo "::error::$label: the native build failed (exit $rc)" >&2
    cat "$bin.log" >&2
    fail=1
  elif grep -q 'error\[' "$bin.log"; then
    echo "::error::$label: the native build reported an error" >&2
    cat "$bin.log" >&2
    fail=1
  else
    echo "native stdlib type-check gate ($label): OK"
  fi
}

kernel_files=("$std_dir"/_kernel_native/*.l)
write_importer "$work/kernels.l" NativeStdlibGateKernels "${kernel_files[@]}"
expect_clean "every _kernel_native package" "$work/kernels.l"

public_files=("$std_dir"/*.l)
write_importer "$work/public.l" NativeStdlibGatePublic "${public_files[@]}"
expect_clean "every public Std package" "$work/public.l"

# A temp copy of the stdlib with one ill-typed kernel.  `Std.TcpHost` is
# imported by `Std.HttpHost`, so the second build reaches it only
# transitively.
broken_std="$work/std"
cp -R "$std_dir" "$broken_std"
broken_kernel="$broken_std/_kernel_native/tcp_host.l"
cat >> "$broken_kernel" <<'LYR'

func nativeStdlibGateIllTyped(): Int {
  val b: Bool = 1
  0
}
LYR

# expect_kernel_rejected <label> <source.l>
expect_kernel_rejected() {
  local label="$1" src="$2" bin="${2%.l}" rc bad=0
  set +e
  LYRIC_STD_PATH="$broken_std" "$lyric_bin" build --target native "$src" -o "$bin" > "$bin.log" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    echo "::error::$label: expected a non-zero exit for an ill-typed stdlib kernel, got 0" >&2
    bad=1
  fi
  if ! grep -F "$broken_kernel" "$bin.log" | grep -q 'error\[T0060\]'; then
    echo "::error::$label: expected an error[T0060] diagnostic naming $broken_kernel" >&2
    bad=1
  fi
  if [ -e "$bin" ]; then
    echo "::error::$label: a binary was written at $bin" >&2
    bad=1
  fi
  if [ "$bad" -ne 0 ]; then
    cat "$bin.log" >&2
    fail=1
  else
    echo "native stdlib type-check gate ($label): OK"
  fi
}

cat > "$work/direct.l" <<'LYR'
package NativeStdlibGateDirect

import Std.TcpHost

func main(): Int {
  0
}
LYR
expect_kernel_rejected "ill-typed kernel, imported directly" "$work/direct.l"

cat > "$work/transitive.l" <<'LYR'
package NativeStdlibGateTransitive

import Std.HttpHost

func main(): Int {
  0
}
LYR
expect_kernel_rejected "ill-typed kernel, reached through Std.HttpHost" "$work/transitive.l"

exit "$fail"
