#!/usr/bin/env bash
# verify-reproducible-emit.sh — prove the self-hosted MSIL emitter is
# byte-for-byte reproducible.
#
# The self-hosted backend (lyric-compiler/msil/) emits a deterministic image
# by construction: the Module MVID is fixed (lowering.l writes a zero GUID) and
# the PE TimeDateStamp is zero (assembler.l), and no wall-clock value is baked
# into any heap or resource.  So compiling the *same* sources twice MUST yield
# identical bytes — we verify that with an exact `cmp`, NOT a normalizing diff.
#
# This is the trust-anchor reproducibility check for Q-dist-001: the shipped
# self-hosted binary is produced by this emitter, so its byte-stability is the
# property a signed, reproducible release depends on.  Contrast the F# stage-0
# emitter, which bakes a random MVID, a real PE timestamp, and a `build_date`
# wall-clock into `Lyric.SdkVersion`; it is non-reproducible by design and is
# on a deletion schedule, so it is NOT the trust anchor (see scripts/bootstrap.sh
# stage 2 for the informational stage-0 diagnostic).
#
# Two corpora are supported:
#
#   manifest mode — build one `lyric.toml`/`lyric.full.toml` bundle twice and
#                   compare the single output assembly.
#       verify-reproducible-emit.sh manifest <lyric-bin> <manifest> [asm-name]
#
#   closure mode  — self-host-compile the WHOLE `Lyric.Cli` compiler closure
#                   (every Lyric.* / Msil.* / Jvm.* package + its stdlib import
#                   closure) twice via `--internal-perpackage-build` and compare
#                   every emitted DLL.  This is the strongest reproducibility
#                   property achievable today: the entire self-hosted compiler
#                   emits byte-identically run-to-run.
#       verify-reproducible-emit.sh closure <lyric-bin>
#
# For backward compatibility, an invocation whose first argument is an existing
# executable (not the word `manifest`/`closure`) is treated as manifest mode
# with the lyric binary first.
#
# Exit status is non-zero (and a diff is printed) if any two builds differ.

set -euo pipefail

usage() {
  echo "usage:" >&2
  echo "  verify-reproducible-emit.sh manifest <lyric-bin> <manifest> [asm-name]" >&2
  echo "  verify-reproducible-emit.sh closure  <lyric-bin>" >&2
  exit 2
}

MODE="${1:?$(usage)}"
# Backward-compat: `verify-reproducible-emit.sh <lyric-bin> <manifest> [asm]`.
if [[ "$MODE" != "manifest" && "$MODE" != "closure" ]]; then
  MODE="manifest"
else
  shift
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/lyric-repro.XXXXXX")"
trap 'rm -rf "$work"' EXIT

verify_manifest() {
  local lyric_bin="${1:?lyric binary required}"
  local manifest="${2:?manifest path required}"
  local asm_name="${3:-}"

  [[ -x "$lyric_bin" ]] || { echo "FATAL: lyric binary not executable: $lyric_bin" >&2; exit 1; }
  [[ -f "$manifest"   ]] || { echo "FATAL: manifest not found: $manifest" >&2; exit 1; }

  # Derive the output assembly file name from the manifest's `output_assembly`
  # when the caller didn't pass one explicitly.  The two builds use the SAME
  # file name in two SEPARATE directories so the assembly identity is identical
  # and only the output directory differs — confirming the path is not baked
  # into the image.
  if [[ -z "$asm_name" ]]; then
    asm_name="$(sed -n 's/^[[:space:]]*output_assembly[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest" | head -1)"
  fi
  [[ -n "$asm_name" ]] || { echo "FATAL: could not determine output assembly name; pass it as the last arg" >&2; exit 1; }

  mkdir -p "$work/a" "$work/b"
  local pass
  for pass in a b; do
    echo "[repro] building $manifest (pass $pass) via $lyric_bin"
    if ! "$lyric_bin" build --manifest "$manifest" -o "$work/$pass/$asm_name" \
          --target dotnet > "$work/$pass.log" 2>&1; then
      echo "FATAL: self-hosted build failed for $manifest" >&2
      cat "$work/$pass.log" >&2
      exit 1
    fi
  done

  local a="$work/a/$asm_name" b="$work/b/$asm_name"
  [[ -f "$a" && -f "$b" ]] || { echo "FATAL: expected output $asm_name missing after build" >&2; exit 1; }

  if cmp -s "$a" "$b"; then
    echo "[repro] OK: self-hosted emit is byte-for-byte reproducible ($asm_name, $(wc -c < "$a" | tr -d ' ') bytes)"
    return 0
  fi
  echo "[repro] FAIL: $asm_name differs between two self-hosted builds" >&2
  cmp -l "$a" "$b" | head -40 >&2
  echo "[repro] total differing bytes: $(cmp -l "$a" "$b" | wc -l | tr -d ' ')" >&2
  exit 1
}

verify_closure() {
  local lyric_bin="${1:?lyric binary required}"
  [[ -x "$lyric_bin" ]] || { echo "FATAL: lyric binary not executable: $lyric_bin" >&2; exit 1; }

  cat > "$work/driver.l" <<'EOF'
// Auto-generated driver for the whole-compiler reproducibility check.
// Importing Lyric.Cli makes the self-hosted per-package emitter discover and
// emit the entire compiler-package closure plus its stdlib import closure.
package SelfHostedCompilerRepro
import Lyric.Cli
func main(): Unit { }
EOF

  local pass
  for pass in a b; do
    echo "[repro] self-host-compiling the Lyric.Cli closure (pass $pass) via $lyric_bin"
    if ! "$lyric_bin" --internal-perpackage-build "$work/driver.l" "$work/$pass" \
          > "$work/$pass.log" 2>&1; then
      echo "FATAL: --internal-perpackage-build failed" >&2
      cat "$work/$pass.log" >&2
      exit 1
    fi
  done

  local total=0 match=0 diffs=0 missing=0
  local f n
  shopt -s nullglob
  for f in "$work/a"/*.dll; do
    n="$(basename "$f")"
    total=$((total + 1))
    if [[ ! -f "$work/b/$n" ]]; then
      echo "[repro]   MISSING in pass b: $n" >&2
      missing=$((missing + 1))
      continue
    fi
    if cmp -s "$f" "$work/b/$n"; then
      match=$((match + 1))
    else
      echo "[repro]   DIFF: $n (differs between two self-hosted builds)" >&2
      diffs=$((diffs + 1))
    fi
  done
  shopt -u nullglob

  if [[ $total -eq 0 ]]; then
    echo "FATAL: per-package emit produced no DLLs" >&2
    exit 1
  fi
  if [[ $diffs -eq 0 && $missing -eq 0 ]]; then
    echo "[repro] OK: whole self-hosted compiler closure is byte-for-byte reproducible ($match/$total DLLs)"
    return 0
  fi
  echo "[repro] FAIL: self-hosted compiler closure is NOT reproducible ($diffs diff, $missing missing of $total)" >&2
  exit 1
}

case "$MODE" in
  manifest) verify_manifest "$@" ;;
  closure)  verify_closure  "$@" ;;
  *)        usage ;;
esac
