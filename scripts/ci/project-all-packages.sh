#!/usr/bin/env bash
# A project build checks and emits every package its manifest lists that
# applies to the target, not only the packages the entry package's imports
# reach (#8357).  examples/jvm-unreached-package lists three packages: the
# entry "App" (imports nothing), "Unreached" (a type error, imported by no
# one) and "DotnetOnly" (a type error, gated to dotnet by a file-level
# @cfg(target)).
#
#   - --target jvm reports "Unreached" and not "DotnetOnly";
#   - --target dotnet reports "Unreached" too, and "DotnetOnly" once that is fixed;
#   - with "Unreached" fixed, --target jvm builds and the JAR runs, which is
#     how a package says it does not apply to the JVM: its own @cfg, never an
#     accident of reachability.
#
#   LYRIC_BIN=<lyric> bash scripts/ci/project-all-packages.sh
set -euo pipefail
lyric_bin="${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
cp -r "$repo/examples/jvm-unreached-package" "$work/proj"
out="$work/out"
err="$work/err"

fail() {
  echo "FAIL: $1"
  echo "--- stdout"; cat "$out"
  echo "--- stderr"; cat "$err"
  exit 1
}

build() {
  local rc=0
  "$lyric_bin" build --manifest "$work/proj/lyric.toml" "$@" > "$out" 2> "$err" || rc=$?
  echo "$rc"
}

rc="$(build --target jvm -o "$work/p.jar")"
[ "$rc" -ne 0 ] || fail "jvm: the unreached package's type error must fail the build"
grep -q "unreached.l: error\[T0" "$err" || fail "jvm: expected the type error attributed to unreached.l"
if grep -q "dotnet_only.l" "$err"; then
  fail "jvm: the dotnet-only package must not be checked on the JVM"
fi
echo "PASS: jvm reports the unreached package, not the dotnet-only one"

rc="$(build --target dotnet)"
[ "$rc" -ne 0 ] || fail "dotnet: expected a failing build"
grep -q "unreached.l: error\[T0" "$err" || fail "dotnet: expected the unreached package's type error"
echo "PASS: dotnet reports the unreached package"

cat > "$work/proj/src/unreached.l" <<'LYR'
package Unreached

pub func fine(): Int {
  1
}
LYR
rc="$(build --target jvm -o "$work/p.jar")"
[ "$rc" -eq 0 ] || fail "jvm: with the unreached package fixed the build must pass"
java -jar "$work/p.jar" > "$out" 2> "$err" || fail "jvm: the built JAR must run"
grep -qx "hello" "$out" || fail "jvm: expected the entry package's output"
listing="$(unzip -l "$work/p.jar")"
grep -q "Unreached.class" <<< "$listing" || fail "jvm: the unreached package must be emitted into the JAR"
echo "PASS: jvm builds once the unreached package is fixed, and emits it"

rc="$(build --target dotnet)"
[ "$rc" -ne 0 ] || fail "dotnet: the dotnet-only package's type error must fail the build"
grep -q "dotnet_only.l: error\[T0" "$err" || fail "dotnet: expected the dotnet-only package's type error"
echo "PASS: dotnet checks the dotnet-only package"
