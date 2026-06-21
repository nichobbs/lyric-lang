#!/usr/bin/env bash
# stage-selfhosted-stdlib.sh — ship the stdlib packages the F# stage-0 emitter
# cannot build (#2592) by emitting them with the self-hosted emitter and copying
# them into the toolchain lib dir(s).
#
# Why this exists: the F# stage-0 CLI-bundle only emits the compiler's import
# closure plus the F#-buildable bundle "smoke set", so packages F# cannot
# compile (e.g. Std.Sort's typed-lambda generics) never ship — a user program
# importing them fails at run time with `Could not load file or assembly
# 'Lyric.Stdlib.Sort'`.  The self-hosted emitter CAN build them.  After staging,
# this script also replaces the F#-built Core/Collections with self-hosted ones
# (which use CLR arity-suffix naming) and patches TypeRefs in all remaining
# F#-built DLLs to match, so the whole lib dir has a consistent ABI.
#
# Scope: only packages VERIFIED to bind against the F#-built stdlib are shipped
# (see CURATED_PACKAGES below).  Packages with known self-hosted binding bugs are
# deliberately excluded — they need the self-hosted-built-toolchain ABI work first:
#   * Std.Random  — System.Random.Next instance mis-bind
#   * Std.Format  — Int32.ToString(int, string) extern not found
# Previously excluded (now fixed by D-progress-480, #2592 slice 1):
#   * Std.Xml / Std.Yaml — non-generic union-case ctor concrete-collection field
#     mismatch (List<object> stored into List<T> field → InvalidCastException on match)
#
# Usage: stage-selfhosted-stdlib.sh <lyric-binary> <lib-dir> [<lib-dir> ...]
set -euo pipefail

LYRIC_BIN="${1:?usage: stage-selfhosted-stdlib.sh <lyric-binary> <lib-dir>...}"
shift
LIB_DIRS=("$@")
if [[ ${#LIB_DIRS[@]} -eq 0 ]]; then
  echo "stage-selfhosted-stdlib: no target lib dirs given" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STD_DIR="$REPO_ROOT/lyric-stdlib/std"

# Verified-to-bind leaf packages F# cannot ship.
CURATED_PACKAGES=(Sort Iter SecureRandom Regex Log Http Rest HttpServer Xml Yaml Json JsonHost)

emit_dir="$(mktemp -d)"
trap 'rm -rf "$emit_dir"' EXIT

# Build a driver importing every public Std.* module so emitPerPackageClosure
# produces the full self-hosted stdlib (the curated packages + their host
# extern-boundary sub-packages all land in one consistent emit).
driver="$emit_dir/driver.l"
{
  echo "package SelfHostedStdlibStage"
  # Import all public Std.* packages plus kernel-boundary packages (e.g., Std.HttpServer)
  grep -rhoE '^package Std\.[A-Za-z.]+' "$STD_DIR"/*.l "$STD_DIR"/_kernel/*.l | sed 's/^package /import /' | sort -u
  echo "func main(): Unit { }"
} > "$driver"

out="$emit_dir/out"
# The driver imports all Std.* packages (including known-buggy ones like Std.Random
# and Std.Format) so emitPerPackageClosure produces every *Host sub-package in one
# consistent emit.  If a non-curated package develops a compile error the build may
# fail entirely, leaving curated DLLs unproduced.  Trap that case clearly so the
# root cause (a regression in a non-curated package) is visible rather than looking
# like a curated-package failure.  See issue #2824.
if ! "$LYRIC_BIN" --internal-perpackage-build "$driver" "$out" 2>&1; then
  echo "stage-selfhosted-stdlib: --internal-perpackage-build failed (see above)." >&2
  echo "  This may be caused by a compile error in a non-curated Std.* package" >&2
  echo "  (e.g. Std.Random, Std.Format) that is included in the driver for *Host" >&2
  echo "  sub-package consistency.  Check the error above and the excluded-packages" >&2
  echo "  list in this script.  Tracking: #2824." >&2
  exit 1
fi

# DLLs to stage: the curated packages plus every host extern-boundary sub-package
# (`*Host`), which the curated packages depend on at run time and which F# does
# not necessarily ship.  Unused hosts are harmless (never loaded without their
# consumer package).
to_stage=()
missing_curated=0
for p in "${CURATED_PACKAGES[@]}"; do
  dll="$out/Lyric.Stdlib.$p.dll"
  if [[ ! -f "$dll" ]]; then
    echo "stage-selfhosted-stdlib: ERROR: expected $dll was not emitted after a successful build." >&2
    echo "  The build succeeded but '$p' is missing from the output (#2824)." >&2
    missing_curated=1
    continue
  fi
  to_stage+=("$dll")
done
# Report every missing package above, then fail: staging must not exit 0
# with an incomplete curated set (#3185).
if (( missing_curated )); then
  exit 1
fi
for h in "$out"/Lyric.Stdlib.*Host.dll; do
  [[ -f "$h" ]] && to_stage+=("$h")
done

staged=0
for dir in "${LIB_DIRS[@]}"; do
  [[ -d "$dir" ]] || continue
  for dll in "${to_stage[@]}"; do
    # cp -n: never clobber an F#-built DLL already present; only fill gaps.
    if [[ ! -f "$dir/$(basename "$dll")" ]]; then
      cp "$dll" "$dir/"
      staged=$((staged + 1))
    fi
  done
done

echo "stage-selfhosted-stdlib: staged $staged DLL(s) into ${#LIB_DIRS[@]} lib dir(s) (curated: ${CURATED_PACKAGES[*]})"

# ── ABI-suffix alignment ──────────────────────────────────────────────────────
# The F# bootstrap emitter (used by LYRIC_BOOTSTRAP_MINT=1) names generic
# TypeDefs WITHOUT the CLR arity suffix: Option, Result, etc.  The
# self-hosted MSIL emitter always adds the suffix (Option`1, Result`2) in
# every DLL it produces — including in compiled user code.  This mismatch
# causes a TypeLoadException at runtime ("Could not load type
# 'Std.Core.Option`1' from assembly 'Lyric.Stdlib.Core'") for any user
# program that uses Option or Result.
#
# Fix: patch the TypeDef entries in F#-built Lyric.Stdlib.*.dll files
# in-place (e.g. Option → Option`1 in Lyric.Stdlib.Core.dll), then patch
# TypeRefs in every DLL in the lib dirs to match.  This keeps the F#-built
# DLLs' method ABIs intact — we do NOT replace them with self-hosted
# versions, because the self-hosted stdlib has a different ABI for generic
# functions (e.g. unwrapOr) that the F#-built TypeChecker was compiled
# against.  Both passes are idempotent.
#
# The rename map is derived from the self-hosted per-package emit output
# in $out (the temp dir), not from the lib dirs, since the lib dirs still
# hold the F#-built DLLs (no arity suffix) at this point.
patch_log="$REPO_ROOT/.bootstrap/patch-stdlib-generics.log"
mkdir -p "$(dirname "$patch_log")"
echo "stage-selfhosted-stdlib: patching TypeDefs+TypeRefs in lib dirs (log: $patch_log)"
if ! dotnet fsi "$REPO_ROOT/scripts/patch-stdlib-generics.fsx" --source "$out" "${LIB_DIRS[@]}" \
     > "$patch_log" 2>&1; then
  echo "stage-selfhosted-stdlib: ERROR: patch-stdlib-generics.fsx failed" >&2
  cat "$patch_log" >&2
  exit 1
fi
cat "$patch_log"
