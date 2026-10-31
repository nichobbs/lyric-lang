#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# release-contracts-e2e.sh — contract checking follows the build profile
# (book chapter 17, section 17.4; #6263).
#
#   bash scripts/ci/release-contracts-e2e.sh [target...]
#
# One program with three violated contracts, built four ways per target:
#
#   debug                      every contract is checked: the internal
#                              `ensures:` fails first and the program panics.
#   --release                  `ensures:` and the `requires:` of non-`pub`
#                              functions are not checked; the `requires:` of a
#                              `pub` function still is, so the program reaches
#                              it and panics there, after printing the
#                              internal results.
#   --release --release-contracts
#                              every contract is checked again.
#   --release, package annotated @runtime_checked(release_contracts = full)
#                              every contract is checked again.
#
# With no arguments it checks dotnet, jvm and native.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
# Absolute, so a `cd` into a scratch project does not lose it (CI passes a
# repo-relative LYRIC_BIN).
case "$lyric_bin" in /*) ;; *) lyric_bin="$REPO_ROOT/$lyric_bin" ;; esac
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the release contracts e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

body='
func internalEnsures(n: in Int): Int
  ensures: result > 1000
{
  n * 2
}

func internalRequires(n: in Int): Int
  requires: n > 1000
{
  n
}

pub func publicRequires(n: in Int): Int
  requires: n > 1000
{
  n
}

func main(): Int {
  println("ensures ${internalEnsures(3)}")
  println("internal requires ${internalRequires(5)}")
  println("public requires ${publicRequires(7)}")
  return 0
}
'
printf 'package ReleaseContracts\n%s' "$body" > "$work/plain.l"
printf '@runtime_checked(release_contracts = full)\npackage ReleaseContractsFull\n%s' "$body" > "$work/full.l"

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
  local target="$1" tag="$2"
  case "$target" in
    dotnet) echo "$work/$tag-$target/prog.dll" ;;
    jvm) echo "$work/$tag-$target/prog.jar" ;;
    native) echo "$work/$tag-$target/prog" ;;
  esac
}

fail=0
# check TARGET TAG SOURCE EXPECT-PANIC-TEXT LINES-THAT-MUST-PRINT... -- flags...
check() {
  local target="$1" tag="$2" src="$3" panic="$4" printed="$5"
  shift 5
  local out
  out="$(out_name "$target" "$tag")"
  mkdir -p "$(dirname "$out")"
  local flags=(--target "$target" "$@")
  if ! "$lyric_bin" build "${flags[@]}" "$src" -o "$out" >"$work/build.log" 2>&1; then
    echo "::error::$tag build failed on --target $target" >&2
    cat "$work/build.log" >&2
    fail=1
    return
  fi
  set +e
  run_built "$target" "$out" >"$work/run.log" 2>&1
  local status=$?
  set -e
  if [[ $status -eq 0 ]] || ! grep -q "$panic" "$work/run.log"; then
    echo "::error::$tag on --target $target: expected a panic matching '$panic' (exit $status)" >&2
    cat "$work/run.log" >&2
    fail=1
    return
  fi
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! grep -qx "$line" "$work/run.log"; then
      echo "::error::$tag on --target $target: expected output line '$line' before the panic" >&2
      cat "$work/run.log" >&2
      fail=1
    fi
  done <<<"$printed"
  if [[ -z "$printed" ]] && grep -q "^ensures \|^internal requires " "$work/run.log"; then
    echo "::error::$tag on --target $target: a contract that must be checked let the program run on" >&2
    cat "$work/run.log" >&2
    fail=1
  fi
}

for target in "${targets[@]}"; do
  shape=()
  if [[ "$target" != native ]]; then
    shape=(--shape portable)
  fi
  check "$target" debug "$work/plain.l" "internalEnsures" ""
  check "$target" release "$work/plain.l" "publicRequires" $'ensures 6\ninternal requires 5' --release "${shape[@]}"
  check "$target" release-keep "$work/plain.l" "internalEnsures" "" --release --release-contracts "${shape[@]}"
  check "$target" release-annotated "$work/full.l" "internalEnsures" "" --release "${shape[@]}"
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "contracts follow the build profile on: ${targets[*]}"
