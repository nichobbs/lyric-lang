#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# project-package-import-reachability-e2e.sh — end-to-end regression test for
# #7583: in a multi-package `[project.packages]` manifest build, a package
# that reads/annotates/matches a name in another PROJECT package it never
# imports must be rejected with T0020 on BOTH targets, not just `--target
# jvm`.  `--target dotnet` used to build the unimported forms silently
# because `Msil.Bridge`'s per-package `ImportedPackage` list only carried the
# packages reachable from a package's own transitive import closure, so the
# type checker's reachability check (`checkQualifiedPackageRef` /
# `qualifiedPkgReachable`) never saw the referenced package's symbols at all
# and its `symTablePackageHasAnySymbol` guard never fired.
#
#   BUILD_CONFIG=Release bash scripts/ci/project-package-import-reachability-e2e.sh
#
# Drives the real CLI over a throwaway two-package project on both
# `--target dotnet` and `--target jvm`:
#   - an unimported qualified VALUE read (`Lib.Net.Rest.someVal`)
#   - an unimported qualified TYPE annotation (`val w: Lib.Net.Rest.Widget`)
#   - an unimported qualified CALL (`Lib.Net.Rest.ping()`)
# must each report T0020 on both targets, and the corresponding IMPORTED
# forms must build cleanly and produce the correct runtime value on both
# targets. Invoked from `compiler-self-tests-batch.sh` (whose CI job already
# has Java 21 installed, same precedent as distinct-factory-import-e2e.sh),
# so it needs no ci.yml step of its own.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping project-package-import-reachability e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/proj/src"
cat > "$work/proj/src/rest.l" <<'EOF'
package Lib.Net.Rest

pub val someVal: Int = 42

pub record Widget {
  name: String
}

pub func ping(): Int {
  7
}
EOF

write_manifest() {
  cat > "$work/proj/lyric.toml" <<TOML
[package]
name = "ProjPkgImportReach"
version = "0.1.0"

[project]
name = "ProjPkgImportReach"
output = "single"
output_assembly = "ProjPkgImportReach.dll"

[project.packages]
"Lib.Net.Rest" = "src/rest.l"
"App" = "src/main.l"
TOML
}

failures=0

# expect_t0020 <label> <main.l body written to $work/proj/src/main.l>
expect_t0020() {
  local label="$1"
  local out="$work/out.txt" rc=0
  write_manifest
  for target in dotnet jvm; do
    "$lyric_bin" build --target "$target" --manifest "$work/proj/lyric.toml" -o "$work/out.dll" > "$out" 2>&1 && rc=0 || rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "FAIL [$label, $target]: expected a build failure (T0020) but the build succeeded" >&2
      failures=$((failures + 1))
      continue
    fi
    if ! grep -q 'T0020' "$out"; then
      echo "FAIL [$label, $target]: expected T0020 in output" >&2
      cat "$out" >&2
      failures=$((failures + 1))
      continue
    fi
    echo "ok   [$label, $target]: T0020 reported as expected"
  done
}

# expect_ok_and_run <label> <expected exit code>
expect_ok_and_run() {
  local label="$1" want="$2"
  local out="$work/out.txt" rc=0
  write_manifest
  for target in dotnet jvm; do
    "$lyric_bin" run --target "$target" --manifest "$work/proj/lyric.toml" > "$out" 2>&1 && rc=0 || rc=$?
    if [ "$rc" -ne "$want" ]; then
      echo "FAIL [$label, $target]: expected exit $want, got $rc" >&2
      cat "$out" >&2
      failures=$((failures + 1))
      continue
    fi
    echo "ok   [$label, $target]: built and ran, exit $rc"
  done
}

# --- Unimported forms: T0020 on both targets ---------------------------

cat > "$work/proj/src/main.l" <<'EOF'
package App

func main(): Int {
  Lib.Net.Rest.someVal
}
EOF
expect_t0020 "unimported qualified value read"

cat > "$work/proj/src/main.l" <<'EOF'
package App

func f(w: in Lib.Net.Rest.Widget): Int {
  0
}

func main(): Int {
  0
}
EOF
expect_t0020 "unimported qualified type annotation"

cat > "$work/proj/src/main.l" <<'EOF'
package App

func main(): Int {
  Lib.Net.Rest.ping()
}
EOF
expect_t0020 "unimported qualified call"

# --- Imported forms: clean build, correct runtime value, both targets ---

cat > "$work/proj/src/main.l" <<'EOF'
package App

import Lib.Net.Rest

func main(): Int {
  Lib.Net.Rest.someVal
}
EOF
expect_ok_and_run "imported qualified value read" 42

cat > "$work/proj/src/main.l" <<'EOF'
package App

import Lib.Net.Rest

func widgetName(w: in Lib.Net.Rest.Widget): String {
  w.name
}

func main(): Int {
  Lib.Net.Rest.ping()
}
EOF
expect_ok_and_run "imported qualified type annotation + call" 7


# --- #7592: bare-name collision between two sibling project packages -----
#
# Pins docs/01 §9.2's import rule for bare names (D141, #7535): now that
# every project package is registered on both targets, an unimported
# sibling's same-named function must not capture a bare call.
#
# Two sibling packages declare the SAME bare function name with the SAME
# signature but different behaviour. The consumer imports only one of them
# and calls the name bare (unqualified) — it must resolve to the IMPORTED
# one, not to whichever package happened to register the name first
# bundle-wide, on both targets.

mkdir -p "$work/coll/src"
cat > "$work/coll/src/a.l" <<'EOF'
package Coll.A

pub func pick(): Int {
  1
}
EOF
cat > "$work/coll/src/b.l" <<'EOF'
package Coll.B

pub func pick(): Int {
  2
}
EOF

write_coll_manifest() {
  local imported="$1"
  cat > "$work/coll/lyric.toml" <<TOML
[package]
name = "BareNameCollision"
version = "0.1.0"

[project]
name = "BareNameCollision"
output = "single"
output_assembly = "BareNameCollision.dll"

[project.packages]
"Coll.A" = "src/a.l"
"Coll.B" = "src/b.l"
"App" = "src/main.l"
TOML
  cat > "$work/coll/src/main.l" <<EOF
package App

import Coll.$imported

func main(): Int {
  pick()
}
EOF
}

# expect_ok_and_run_coll <label> <imported package letter> <expected exit>
expect_ok_and_run_coll() {
  local label="$1" imported="$2" want="$3"
  local out="$work/out.txt" rc=0
  write_coll_manifest "$imported"
  for target in dotnet jvm; do
    "$lyric_bin" run --target "$target" --manifest "$work/coll/lyric.toml" > "$out" 2>&1 && rc=0 || rc=$?
    if [ "$rc" -ne "$want" ]; then
      echo "FAIL [$label, $target]: expected exit $want (from Coll.$imported.pick()), got $rc" >&2
      cat "$out" >&2
      failures=$((failures + 1))
      continue
    fi
    echo "ok   [$label, $target]: bare pick() resolved to the imported Coll.$imported, exit $rc"
  done
}

expect_ok_and_run_coll "bare-name collision resolves to the imported sibling (A)" "A" 1
expect_ok_and_run_coll "bare-name collision resolves to the imported sibling (B)" "B" 2

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures project-package-import-reachability e2e case(s) failed (#7583/#7592)" >&2
  exit 1
fi
echo "project-package-import-reachability e2e passed: unimported qualified project-package references report T0020 on both dotnet and jvm project builds, imported ones still build and run correctly (#7583), and a bare-name collision between two sibling packages resolves to the one the consumer actually imports on both targets (#7592)"
