#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# overflow-profile-e2e.sh — integer overflow follows the build profile (D163).
#
#   bash scripts/ci/overflow-profile-e2e.sh [target...]
#
# Builds one program twice per target: a debug build, whose `Int` overflow
# must panic with `arithmetic overflow: Int addition` and exit non-zero, and a
# `--release` build, whose overflow must wrap.  `overflow_self_test.l` and
# `overflow_panic_self_test.l` cover the operators in-process, but a test
# cannot observe the build profile's effect on a separately built program,
# and the native target cannot catch a panic at all.  With no arguments it
# checks dotnet, jvm and native.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the overflow profile e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/ovf.l" <<'EOF'
package OverflowProfile

func big(): Int = 2147483647

func main(): Int {
  val x = big() + 1
  println("wrapped ${x}")
  return 0
}
EOF

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then
  targets=(dotnet jvm native)
fi

run_built() {
  local target="$1" out="$2"
  case "$target" in
    dotnet) dotnet "$out" ;;
    jvm) java -jar "$out" ;;
    native) "$out" ;;
  esac
}

out_name() {
  local target="$1" profile="$2"
  case "$target" in
    dotnet) echo "$work/$profile-$target/ovf.dll" ;;
    jvm) echo "$work/$profile-$target/ovf.jar" ;;
    native) echo "$work/$profile-$target/ovf" ;;
  esac
}

fail=0
for target in "${targets[@]}"; do
  for profile in debug release; do
    out="$(out_name "$target" "$profile")"
    mkdir -p "$(dirname "$out")"
    flags=(--target "$target")
    if [[ "$profile" == release ]]; then
      flags+=(--release)
      if [[ "$target" != native ]]; then
        flags+=(--shape portable)
      fi
    fi
    if ! "$lyric_bin" build "${flags[@]}" "$work/ovf.l" -o "$out" >"$work/build.log" 2>&1; then
      echo "::error::$profile build failed on --target $target" >&2
      cat "$work/build.log" >&2
      fail=1
      continue
    fi
    set +e
    run_built "$target" "$out" >"$work/run.log" 2>&1
    status=$?
    set -e
    if [[ "$profile" == debug ]]; then
      if [[ $status -eq 0 ]] || ! grep -q "arithmetic overflow: Int addition" "$work/run.log"; then
        echo "::error::debug build on --target $target did not panic on Int overflow (exit $status)" >&2
        cat "$work/run.log" >&2
        fail=1
      fi
    else
      if [[ $status -ne 0 ]] || ! grep -qx "wrapped -2147483648" "$work/run.log"; then
        echo "::error::release build on --target $target did not wrap on Int overflow (exit $status)" >&2
        cat "$work/run.log" >&2
        fail=1
      fi
    fi
  done
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "integer overflow panics in debug and wraps in release on: ${targets[*]}"
