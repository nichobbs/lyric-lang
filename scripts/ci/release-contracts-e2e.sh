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
# A second set of programs repeats the policy for methods (#8680): one each for
# a record method (of a `pub` and of a private record), an `impl` method whose
# interface method has a `requires:`, and
# a protected-type entry and func.  A record or protected-type member takes its
# type's visibility; an `impl` method is reached through its interface.  In
# each, the `ensures:` and the `requires:` of a non-`pub` member are unchecked in a release build (the program prints
# their results), while a `pub` member's `requires:` and an interface method's
# `requires:` still panic.  A protected type keeps its `invariant:`.
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

mk_member() {
  # mk_member NAME BODY: write $work/NAME.l as package Members<NAME>.
  printf '%s\n' "package Members$1" "$2" > "$work/$1.l"
}

mk_member record '
record Local {
  n: Int

  func internalRequires(self: in Local): Int
    requires: self.n > 1000
  {
    self.n
  }
}

pub record Counter {
  n: Int

  func ensuresOnly(self: in Counter): Int
    ensures: result > 1000
  {
    self.n * 2
  }

  func publicRequires(self: in Counter): Int
    requires: self.n > 1000
  {
    self.n
  }
}

func main(): Int {
  val c = Counter(n = 3)
  println("ensures ${c.ensuresOnly()}")
  println("internal requires ${Local(n = 3).internalRequires()}")
  println("public requires ${c.publicRequires()}")
  return 0
}'

mk_member protected_pub '
pub protected type Gate {
  var v: Int = 0

  entry open(k: in Int): Int
    requires: k > 1000
  {
    v = k
    k
  }
}

func main(): Int {
  val g = Gate()
  println("before")
  println("open ${g.open(5)}")
  return 0
}'

mk_member impl '
interface Gauge {
  func read(self: in Self): Int
  func poke(self: in Self, k: in Int): Int
    requires: k > 1000
}

record Dial {
  n: Int
}

impl Gauge for Dial {
  func read(self: in Dial): Int
    requires: self.n > 1000
    ensures: result > 1000
  {
    self.n
  }

  func poke(self: in Dial, k: in Int): Int {
    k
  }
}

func main(): Int {
  println("read ${Dial(n = 3).read()}")
  println("poke ${Dial(n = 3).poke(5)}")
  return 0
}'

mk_member inherited '
interface Limited {
  func take(self: in Self, k: in Int): Int
    requires: k > 1000
    ensures: result > 1000
}

record Box {
  n: Int
}

impl Limited for Box {
  func take(self: in Box, k: in Int): Int {
    k - 1000
  }
}

func main(): Int {
  println("before ${Box(n = 1).n}")
  println("ok ${Box(n = 1).take(1500)}")
  println("take ${Box(n = 1).take(5)}")
  return 0
}'

mk_member protected '
protected type Cell {
  var v: Int = 0
  invariant: v >= 0

  entry setAll(k: in Int): Int
    requires: k > 1000
    ensures: result > 1000
  {
    v = k
    k
  }

  func peek(): Int
    ensures: result > 1000
  {
    v
  }

  entry drop(k: in Int): Unit {
    v = v - k
  }
}

func main(): Int {
  val c = Cell()
  println("entry ${c.setAll(5)}")
  println("func ${c.peek()}")
  c.drop(10)
  println("unreachable")
  return 0
}'

mk_member protected_invariant '
protected type Cell {
  var v: Int = 0
  invariant: v >= 0

  entry sub(k: in Int): Unit {
    v = v - k
  }
}

func main(): Int {
  val c = Cell()
  println("before")
  c.sub(1)
  println("unreachable")
  return 0
}'

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

  # Methods: debug checks the first violated clause; release runs past every
  # elided one and stops at the first clause that is kept.
  check "$target" record-debug "$work/record.l" "ensuresOnly" ""
  check "$target" record-release "$work/record.l" "publicRequires" $'ensures 6\ninternal requires 3' --release "${shape[@]}"
  check "$target" record-release-keep "$work/record.l" "ensuresOnly" "" --release --release-contracts "${shape[@]}"
  check "$target" impl-debug "$work/impl.l" "read" ""
  check "$target" impl-release "$work/impl.l" "poke" $'read 3' --release "${shape[@]}"
  check "$target" inherited-debug "$work/inherited.l" "take" $'before 1'
  check "$target" inherited-release "$work/inherited.l" "take" $'before 1\nok 500' --release "${shape[@]}"
  check "$target" protected-pub-release "$work/protected_pub.l" "open" $'before' --release "${shape[@]}"
  check "$target" protected-debug "$work/protected.l" "setAll" ""
  check "$target" protected-release "$work/protected.l" "nvariant" $'entry 5\nfunc 5' --release "${shape[@]}"
  check "$target" protected-invariant "$work/protected_invariant.l" "invariant" $'before' --release "${shape[@]}"
done

if [[ $fail -ne 0 ]]; then
  exit 1
fi
echo "contracts follow the build profile on: ${targets[*]}"
