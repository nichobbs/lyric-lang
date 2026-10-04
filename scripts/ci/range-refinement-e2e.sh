#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# range-refinement-e2e.sh — inline range types are checked wherever a value
# reaches one (#8031).
#
#   bash scripts/ci/range-refinement-e2e.sh [target...]
#
# Builds one program per target and case: a record field at construction, a
# `.copy` argument, a `var` field assignment, a compound assignment to it, a
# union case payload (declared, or an `Option` instantiated with a range), a
# generic record field the expected instantiation makes a range beside one
# that widens (#7813), an argument through a function value, and a list
# element added, assigned and written in a literal.  Each must exit non-zero
# and print the expected `RangeViolated: ... must be in Int range 0 ..= 3`,
# after the in-range use before it and never reaching the line after it.
# `range_refinement_self_test.l` covers the same cases in-process on dotnet
# and the JVM; native cannot catch a panic, so this runs the program.
# With no arguments it checks dotnet, jvm and native.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the range refinement e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/prelude.l" <<'LYR'
package RangeE2e

import Std.Collections

record Slot {
  i: Int range 0 ..= 3
}

record Dial {
  var level: Int range 0 ..= 3
}

union Cmd {
  case Move(steps: Int range 0 ..= 3)
  case Stop
}

record Duo[A, B] {
  wide: A
  narrow: B
}

func at(n: in Int): Int = n

LYR

# name | the in-range use before | the failing statement | expected message
cases=(
  "field|val ok = Slot(i = at(2))|val bad = Slot(i = at(10))|RangeViolated: Slot field i must be in Int range 0 ..= 3"
  "copy|val ok = Slot(i = at(1)).copy(i = at(2))|val bad = ok.copy(i = at(10))|RangeViolated: Slot field i must be in Int range 0 ..= 3"
  "assign|val d = Dial(level = at(0))|d.level = at(10)|RangeViolated: Dial field level must be in Int range 0 ..= 3"
  "compound|val d = Dial(level = at(3))|d.level += at(1)|RangeViolated: Dial field level must be in Int range 0 ..= 3"
  "payload|val ok = Move(steps = at(3))|val bad = Move(steps = at(10))|RangeViolated: Move field steps must be in Int range 0 ..= 3"
  "lambda|val f = { k: Int range 0 ..= 3 -> k }|val bad = f(at(10))|RangeViolated: argument 1 must be in Int range 0 ..= 3"
  "add|var xs: List[Int range 0 ..= 3] = [at(1)]|xs.add(at(10))|RangeViolated: element must be in Int range 0 ..= 3"
  "element|var xs: List[Int range 0 ..= 3] = [at(1)]|xs[0] = at(10)|RangeViolated: element must be in Int range 0 ..= 3"
  "literal|val ok: List[Int range 0 ..= 3] = [at(3)]|val bad: List[Int range 0 ..= 3] = [at(10)]|RangeViolated: element must be in Int range 0 ..= 3"
  "generic|val ok: Duo[Long, Int range 0 ..= 3] = Duo(wide = at(1), narrow = at(3))|val bad: Duo[Long, Int range 0 ..= 3] = Duo(wide = at(1), narrow = at(10))|RangeViolated: Duo field narrow must be in Int range 0 ..= 3"
  "option|val ok: Option[Int range 0 ..= 3] = Some(at(3))|val bad: Option[Int range 0 ..= 3] = Some(at(10))|RangeViolated: Some payload must be in Int range 0 ..= 3"
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
  IFS='|' read -r name before failing expected <<<"$spec"
  {
    cat "$work/prelude.l"
    echo "func main(): Int {"
    echo "  $before"
    echo "  println(\"before\")"
    echo "  $failing"
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
    elif ! grep -q "^before" "$work/run.log" || grep -q "unreachable" "$work/run.log"; then
      echo "::error::case '$name' on --target $target ran the wrong statements around the panic" >&2
      cat "$work/run.log" >&2
      fail=1
    fi
  done
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "inline range panics (${#cases[@]} cases) on: ${targets[*]}"
