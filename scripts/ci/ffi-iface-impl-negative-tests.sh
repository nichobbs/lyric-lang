#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ffi-iface-impl-negative-tests.sh — D105 Phase 2 F0020–F0024 external-
# interface impl conformance negative tests (impl-block-targets-non-
# interface, missing required method, parameter/return type mismatches,
# generic-interface substitution, closed-generic-interface F0021, and the
# F0024 typo-guard). Each fixture must fail the build and report its own
# diagnostic code.
# Extracted from ci.yml's "FFI iface impl F0020–F0023 + generic-iface
# negative tests" step (#6387/check-workflow-size.sh — see
# scripts/ci/self-test.sh's header).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping F0020–F0023 negative tests"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
run_fixture() {
  local diag="$1" file="$2"
  local rc=0
  ( cd "$work" && "$bin_abs" build "$file" ) > "$work/build.out" 2>&1 || rc=$?
  echo "--- $diag fixture build output (rc=$rc) ---"; cat "$work/build.out"
  if [ "$rc" -eq 0 ]; then
    echo "::error::$diag fixture compiled but expected failure"
    exit 1
  fi
  grep -q "$diag" "$work/build.out" || {
    echo "::error::$diag fixture failed but did not report $diag"; exit 1; }
  echo "$diag negative test passed (rc=$rc)"
}
# F0020: impl block targets a non-interface (System.Math is a class).
cat > "$work/f0020_fixture.l" <<'LYR'
package F0020Fixture

extern type NotAnIface = "System.Math"

record R { tag: Int }

impl NotAnIface for R {
}

func main(): Int { 0 }
LYR
run_fixture "F0020" "f0020_fixture.l"
# F0021: impl is missing a required interface method (IDisposable.Dispose).
cat > "$work/f0021_fixture.l" <<'LYR'
package F0021Fixture

extern type IDisposable = "System.IDisposable"

record R { tag: Int }

impl IDisposable for R {
}

func main(): Int { 0 }
LYR
run_fixture "F0021" "f0021_fixture.l"
# F0022: parameter type mismatch (IComparable.CompareTo expects object,
# the impl declares Int).
cat > "$work/f0022_fixture.l" <<'LYR'
package F0022Fixture

extern type IComparable = "System.IComparable"

record R { tag: Int }

impl IComparable for R {
  func CompareTo(other: in Int): Int { 0 }
}

func main(): Int { 0 }
LYR
run_fixture "F0022" "f0022_fixture.l"
# F0023: return type mismatch (IDisposable.Dispose returns void; impl
# declares Int).
cat > "$work/f0023_fixture.l" <<'LYR'
package F0023Fixture

extern type IDisposable = "System.IDisposable"

record R { tag: Int }

impl IDisposable for R {
  func Dispose(): Int { 0 }
}

func main(): Int { 0 }
LYR
run_fixture "F0023" "f0023_fixture.l"
# F0022 on a generic iface: substitution catches a mismatched
# impl-method parameter type — `IEquatable[GenRec]` requires
# `Equals(GenRec)`, but the fixture declares `Equals(Int)`.  Before
# substitution landed (D105 §A follow-up), the F0021–F0023 pass
# bailed per-method on STVar shapes; this fixture pins the new
# substitution path.
cat > "$work/f0022_gen_fixture.l" <<'LYR'
package F0022GenFixture

extern type IEquatable[T] = "System.IEquatable`1"

record GenRec { tag: Int }

impl IEquatable[GenRec] for GenRec {
  func Equals(other: in Int): Bool { false }
}

func main(): Int { 0 }
LYR
run_fixture "F0022" "f0022_gen_fixture.l"
# F0021 on a closed generic interface with a STGenericInst return type
# — `IEnumerable<T>.GetEnumerator(): IEnumerator<T>` is now
# representable (D105 §A nested-generic lift) so the empty impl
# surfaces F0021 (missing method) instead of F0024 (unrepresentable
# shape).  This pin guards both the lift (test would surface F0024
# if STGenericInst regressed) and the structural-validation pass
# (test would surface no diagnostic if F0021 silently passed
# through STGenericInst signatures).
cat > "$work/f0021_gen_fixture.l" <<'LYR'
package F0021GenFixture

extern type IEnumerable[T] = "System.Collections.Generic.IEnumerable`1"

record R { tag: Int }

impl IEnumerable[Int] for R {
}

func main(): Int { 0 }
LYR
run_fixture "F0021" "f0021_gen_fixture.l"
# F0024 — narrow typo guard.  Fires when the iface FQN doesn't
# resolve in any indexed reference-pack / restored-dep assembly,
# AND the metadata index is non-empty (the build is *not* SDK-less).
# SDK-less builds (no reference pack on disk) continue to silent-skip,
# matching the F0015 fallback convention.
cat > "$work/f0024_fixture.l" <<'LYR'
package F0024Fixture

extern type ITypo[T] = "System.IDoesNotExist`1"

record R { tag: Int }

impl ITypo[Int] for R {
}

func main(): Int { 0 }
LYR
run_fixture "F0024" "f0024_fixture.l"
echo "all F0020–F0024 negative tests passed"

