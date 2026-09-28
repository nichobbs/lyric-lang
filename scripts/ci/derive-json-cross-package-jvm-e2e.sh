#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# derive-json-cross-package-jvm-e2e.sh — end-to-end regression test for
# #7502: calling a `@generate(Json)` record's derive-synthesised function
# from a DIFFERENT project package, on `--target jvm`.
#
#   BUILD_CONFIG=Release bash scripts/ci/derive-json-cross-package-jvm-e2e.sh
#
# Drives the real CLI over a throwaway two-package project: `Xp.Api` declares
# an `@generate(Json)` record `Person` nesting an `@generate(Json)` record
# `Address`; `App` imports `Xp.Api` and calls `Person.fromJson(body)` with no
# explicit `: Person`/`: Result[Person, String]` annotation on the decoded
# binding. Before the fix this failed JVM codegen with `auto-FFI: class
# 'Xp.Api.Person' not found` (`Jvm.Bridge.collectDeriveFreeSigs` registered
# only the CURRENT package's own derive-synthesised signatures, never a
# bundled/imported sibling's) even once #7501's name-mangling landed.
#
# `--target dotnet` runs too, as a same-build regression guard (this call
# shape already worked there — #7502 is JVM-only).
#
# Invoked from `compiler-self-tests-batch.sh` (whose CI job already has
# Java 21 installed, same precedent as project-package-import-reachability-
# e2e.sh), so it needs no ci.yml step of its own.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping derive-json-cross-package-jvm e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/proj/src"
cat > "$work/proj/src/api.l" <<'EOF'
package Xp.Api

import Std.Core
import Std.Json

@generate(Json)
pub record Address {
  street: String
  city: String
}

@generate(Json)
pub record Person {
  name: String
  home: Address
}
EOF

cat > "$work/proj/src/main.l" <<'EOF'
package App

import Std.Core
import Std.Json
import Xp.Api

func main(): Int {
  val body = "{\"name\": \"Ada\", \"home\": {\"street\": \"1 Main\", \"city\": \"Lima\"}}"
  val decoded = Xp.Api.Person.fromJson(body)
  match decoded {
    case Ok(p) -> if p.name == "Ada" and p.home.city == "Lima" { 0 } else { 1 }
    case Err(_) -> 2
  }
}
EOF

cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "DeriveJsonCrossPkg"
version = "0.1.0"

[project]
name = "DeriveJsonCrossPkg"
output = "single"
output_assembly = "DeriveJsonCrossPkg.dll"

[project.packages]
"Xp.Api" = "src/api.l"
"App" = "src/main.l"
TOML

failures=0
for target in dotnet jvm; do
  out="$work/out.txt"
  rc=0
  "$lyric_bin" run --target "$target" --manifest "$work/proj/lyric.toml" > "$out" 2>&1 && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL [$target]: expected exit 0 (decoded Person.name == \"Ada\" and home.city == \"Lima\"), got $rc" >&2
    cat "$out" >&2
    failures=$((failures + 1))
  else
    echo "ok   [$target]: Person.fromJson(...) resolved and decoded across the package boundary, exit $rc"
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures derive-json-cross-package-jvm e2e case(s) failed (#7502)" >&2
  exit 1
fi
echo "derive-json-cross-package-jvm e2e passed: a @generate(Json) record's derive-synthesised fromJson resolves and decodes when called from a DIFFERENT project package, on both dotnet and jvm, with no explicit type annotation on the decoded binding (#7502)"
