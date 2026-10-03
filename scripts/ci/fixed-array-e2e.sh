#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fixed-array-e2e.sh — `array[N, T]` bounds checks and elision (D167).
#
#   bash scripts/ci/fixed-array-e2e.sh [target...]
#
# Builds one program per target and case: a read past the end, a write, a
# compound write, a negative index, a nested array, an array field and an empty
# array.  Each must exit non-zero and print `index <i> out of range for
# array[<N>]` exactly, after running the accesses before it and never reaching
# the line after it; an access through a named range-subtype index that proves
# it in bounds must not panic.
# `fixed_array_panic_self_test.l` covers the panics in-process on dotnet and
# the JVM; the native target cannot catch a panic, so this runs the program.
# With no arguments it checks dotnet, jvm and native.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the fixed-array e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/prelude.l" <<'LYR'
package FixedArrayOob

type Slot = Int range 0 ..= 2

record Holder {
  var cells: array[3, Int]
}

func at(n: in Int): Int = n

LYR

# name | statements run before the failing access | the failing access | expected message
cases=(
  "read|val a: array[3, Int] = [10, 20, 30]|println(\"unreachable \${a[at(7)]}\")|index 7 out of range for array[3]"
  "write|var a: array[3, Int]|a[at(7)] = 1|index 7 out of range for array[3]"
  "compound|var a: array[3, Int]|a[at(3)] += 1|index 3 out of range for array[3]"
  "negative|val a: array[3, Int] = [10, 20, 30]|println(\"unreachable \${a[at(0 - 1)]}\")|index -1 out of range for array[3]"
  "nested|var g: array[2, array[3, Int]]|g[1][at(5)] = 1|index 5 out of range for array[3]"
  "outer|var g: array[2, array[3, Int]]|g[at(2)][0] = 1|index 2 out of range for array[2]"
  "field|val h = Holder()|h.cells[at(4)] = 1|index 4 out of range for array[3]"
  "empty|var a: array[0, Int]|println(\"unreachable \${a[at(0)]}\")|index 0 out of range for array[0]"
)

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
  local target="$1" name="$2"
  case "$target" in
    dotnet) echo "$work/$target/$name.dll" ;;
    jvm) echo "$work/$target/$name.jar" ;;
    native) echo "$work/$target/$name" ;;
  esac
}

fail=0
for spec in "${cases[@]}"; do
  IFS='|' read -r name before access expected <<<"$spec"
  {
    cat "$work/prelude.l"
    echo "func main(): Int {"
    echo "  val s: Slot = Slot.from(2)"
    echo "  val ok: array[3, Int] = [10, 20, 30]"
    echo "  println(\"in range \${ok[s]}\")"
    echo "  $before"
    echo "  println(\"before\")"
    echo "  $access"
    echo "  println(\"unreachable\")"
    echo "  return 0"
    echo "}"
  } > "$work/$name.l"
  for target in "${targets[@]}"; do
    out="$(out_name "$target" "$name")"
    mkdir -p "$(dirname "$out")"
    if ! "$lyric_bin" build --target "$target" "$work/$name.l" -o "$out" >"$work/build.log" 2>&1; then
      echo "::error::case '$name' failed to build on --target $target" >&2
      cat "$work/build.log" >&2
      fail=1
      continue
    fi
    set +e
    run_built "$target" "$out" >"$work/run.log" 2>&1
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      echo "::error::case '$name' on --target $target exited 0; it must panic" >&2
      cat "$work/run.log" >&2
      fail=1
    elif ! grep -qF "$expected" "$work/run.log"; then
      echo "::error::case '$name' on --target $target: expected '$expected' (exit $status)" >&2
      cat "$work/run.log" >&2
      fail=1
    elif ! grep -q "in range 30" "$work/run.log" || ! grep -q "^before" "$work/run.log" || grep -q "unreachable" "$work/run.log"; then
      echo "::error::case '$name' on --target $target ran the wrong accesses around the panic" >&2
      cat "$work/run.log" >&2
      fail=1
    fi
  done
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "array bounds panics (${#cases[@]} cases) with the index and length on: ${targets[*]}"
