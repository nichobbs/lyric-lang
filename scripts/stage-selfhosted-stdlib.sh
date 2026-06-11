#!/usr/bin/env bash
# stage-selfhosted-stdlib.sh — ship the stdlib packages the F# stage-0 emitter
# cannot build (#2592) by emitting them with the self-hosted emitter and copying
# them into the toolchain lib dir(s).
#
# Why this exists: the F# stage-0 CLI-bundle only emits the compiler's import
# closure plus the F#-buildable bundle "smoke set", so packages F# cannot
# compile (e.g. Std.Sort's typed-lambda generics) never ship — a user program
# importing them fails at run time with `Could not load file or assembly
# 'Lyric.Stdlib.Sort'`.  The self-hosted emitter CAN build them, and a
# self-hosted-built *leaf* package binds against the F#-built Core/Collections
# (it references generic stdlib types non-suffixed, matching the F# producer),
# so the two coexist in one lib dir.
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
CURATED_PACKAGES=(Sort Iter SecureRandom Regex Log Http Rest Xml Yaml)

emit_dir="$(mktemp -d)"
trap 'rm -rf "$emit_dir"' EXIT

# Build a driver importing every public Std.* module so emitPerPackageClosure
# produces the full self-hosted stdlib (the curated packages + their host
# extern-boundary sub-packages all land in one consistent emit).
driver="$emit_dir/driver.l"
{
  echo "package SelfHostedStdlibStage"
  grep -rhoE '^package Std\.[A-Za-z.]+' "$STD_DIR"/*.l | sed 's/^package /import /' | sort -u
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
