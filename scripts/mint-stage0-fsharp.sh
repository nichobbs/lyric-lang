#!/usr/bin/env bash
# mint-stage0-fsharp.sh — recover a known-good stage-0 `lyric` binary using the
# historical F# bootstrap compiler.
#
# WHY THIS EXISTS
# ---------------
# The self-hosted MSIL emitter shipped in a stage-0 binary that mis-emits large
# / generic cross-assembly metadata (two independent bugs):
#   1. >64 KB string-heap indices were truncated to 2 bytes (fixed in source:
#      "msil: 4-byte heap indices …"), corrupting type/member names in any
#      per-package DLL whose #Strings exceeds 64 KB (notably Lyric.Lyric.Cli).
#   2. generic-union case TypeRefs were emitted without the `\`N` arity suffix
#      (Std.Core.Option_Some vs Option_Some`1 -> TypeLoadException).
# Both are baked into the prebuilt stage-0 binary, and they poison any rebuild
# from it (the next-stage binary won't even load), so there is no self-hosted
# escape from that binary.
#
# The F# bootstrap compiler is a completely separate emitter implementation and
# has NEITHER bug: it produces lean, internally-consistent metadata (the whole
# Lyric.Cli dispatcher is ~6 KB of #Strings).  It was deleted from the tree in
# commit 44a0d1e7 but remains in git history, so we rebuild it from there, use
# it to compile the current self-hosted compiler source into stage-1 DLLs, and
# AOT-link those into a correct stage-0 binary.  That binary carries the current
# (fixed) self-hosted emitter, so all subsequent bootstraps are clean and the
# fix self-sustains — this script is a one-time recovery, not part of the
# steady-state build.
#
# OUTPUT
# ------
#   .bootstrap/stage1/*.dll           — correct stage-1 compiler DLLs (F#-emitted)
#   .bootstrap/stage0-publish/lyric   — AOT stage-0 binary (publish unless FAST=1)
#
# After running this, `scripts/bootstrap.sh --stage 2` uses the minted binary as
# stage-0 (try_bootstrap_from_release reuses .bootstrap/stage0-publish).  Publish
# the minted binary as a GitHub release so future clean checkouts download it.
#
# USAGE
#   scripts/mint-stage0-fsharp.sh           # full AOT publish (release-grade)
#   FAST=1 scripts/mint-stage0-fsharp.sh    # framework-dependent build (dev/CI smoke)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
STAGE1_DIR="$BUILD_DIR/stage1"
STAGE0_PUBLISH_DIR="$BUILD_DIR/stage0-publish"
FAST="${FAST:-0}"

# Last commit that still contains the F# bootstrap compiler (the parent of the
# deletion commit 44a0d1e7).  Override with FS_COMMIT=<sha> if needed.
# `--verify` is required here, not just `rev-parse`: on an unresolvable ref,
# plain `git rev-parse <ref>` still echoes the ref text to stdout before
# failing (a longstanding git quirk), so `$(git rev-parse 44a0d1e7~1
# 2>/dev/null || echo 35c0d2e5)` could capture "44a0d1e7~1\n35c0d2e5" instead
# of just the fallback, corrupting FS_COMMIT with two newline-joined tokens
# (observed on a shallow clone, where the historical commit is unreachable).
# `--verify -q` prints nothing on failure, so the `||` fallback is clean.
FS_COMMIT="${FS_COMMIT:-$(git -C "$REPO_ROOT" rev-parse --verify -q 44a0d1e7~1 2>/dev/null || echo 35c0d2e5)}"

WORKTREE="$BUILD_DIR/fsharp-mint-worktree"
FSBIN_DIR="$BUILD_DIR/fsharp-mint-bin"
FSCACHE="$BUILD_DIR/fsharp-mint-cache"
AOT_PROJ="$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot"

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "[mint] $*"; }

info "F# bootstrap commit: $FS_COMMIT"

# 1. Build the F# bootstrap compiler from history (isolated worktree).
git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
rm -rf "$WORKTREE"
git -C "$REPO_ROOT" worktree add --detach "$WORKTREE" "$FS_COMMIT" >/dev/null
info "building F# compiler (dotnet publish) …"
rm -rf "$FSBIN_DIR"
dotnet publish "$WORKTREE/bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj" \
  --configuration Release --output "$FSBIN_DIR" --nologo -v q \
  || die "F# compiler build failed"
local_fsbin="$FSBIN_DIR/lyric"
[[ -f "$local_fsbin" || -f "$FSBIN_DIR/lyric.dll" ]] || die "F# compiler binary not found"

run_fs() {
  if [[ -x "$FSBIN_DIR/lyric" ]]; then "$FSBIN_DIR/lyric" "$@"; else dotnet "$FSBIN_DIR/lyric.dll" "$@"; fi
}

# 2. Use the F# compiler to compile the CURRENT self-hosted compiler source.
#    The F# emitter caches each compiled package as its own DLL under $TMPDIR;
#    a tiny `import Lyric.Cli` driver pulls the whole compiler+stdlib closure.
rm -rf "$FSCACHE"; mkdir -p "$FSCACHE"
local_driver="$BUILD_DIR/_fsmint_driver.l"
cat > "$local_driver" <<'EOF'
package LyricFsMintDriver
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Int { 0 }
EOF
info "compiling current compiler source with the F# emitter …"
LYRIC_STD_PATH="$REPO_ROOT/lyric-stdlib/std" \
LYRIC_LYRIC_PATH="$REPO_ROOT/lyric-compiler/lyric" \
LYRIC_MSIL_PATH="$REPO_ROOT/lyric-compiler/msil" \
LYRIC_JVM_PATH="$REPO_ROOT/lyric-compiler/jvm" \
TMPDIR="$FSCACHE" TMP="$FSCACHE" TEMP="$FSCACHE" \
  run_fs --internal-build "$local_driver" -o "$BUILD_DIR/_fsmint_out.dll" --target dotnet \
  || die "F# closure compile failed"
rm -f "$local_driver" "$BUILD_DIR/_fsmint_out.dll"

# 3. Harvest the F#-emitted per-package DLLs into stage-1.
# .NET's Path.GetTempPath() honors TMPDIR on Linux/macOS but reads TMP/TEMP on
# Windows, so all three must be set above or the F# emitter's package cache
# lands somewhere other than $FSCACHE and this harvest silently finds nothing
# (#3941).
local_cache_dir="$(ls -d "$FSCACHE"/lyric-stdlib-*/ 2>/dev/null | head -1)"
if [[ -z "$local_cache_dir" ]]; then
  echo "FATAL: no F# package cache produced under $FSCACHE" >&2
  echo "contents of \$FSCACHE ($FSCACHE):" >&2
  ls -la "$FSCACHE" >&2 2>&1 || true
  echo "NOTE: TMP/TEMP were set to $FSCACHE for run_fs above (inline env vars — not visible in this outer shell)" >&2
  die "no F# package cache produced under $FSCACHE"
fi
[[ -f "$local_cache_dir/Lyric.Lyric.Cli.dll" ]] || die "Lyric.Lyric.Cli.dll not in F# cache"
rm -rf "$STAGE1_DIR"; mkdir -p "$STAGE1_DIR"
cp "$local_cache_dir"/*.dll "$STAGE1_DIR/"
info "harvested $(ls "$STAGE1_DIR"/*.dll | wc -l) stage-1 DLLs"

# 4. Retarget System.Private.CoreLib refs -> public facades for AOT linking.
dotnet fsi "$REPO_ROOT/scripts/rewrite-corelib-refs.fsx" "$STAGE1_DIR"/*.dll >/dev/null \
  || die "corelib-ref rewrite failed"

# 5. AOT-link the stage-0 binary.
mkdir -p "$STAGE0_PUBLISH_DIR"
if [[ "$FAST" == "1" ]]; then
  info "FAST=1: framework-dependent build (dev/CI smoke, not release-grade)"
  dotnet build "$AOT_PROJ" --configuration Release --no-incremental \
    -p:StageDir="$STAGE1_DIR" -p:PublishAot=false -o "$STAGE0_PUBLISH_DIR" \
    || die "AOT framework-dependent build failed"
else
  info "AOT publish (release-grade) …"
  dotnet publish "$AOT_PROJ" --configuration Release \
    -p:StageDir="$STAGE1_DIR" -o "$STAGE0_PUBLISH_DIR" \
    || die "AOT publish failed"
fi

git -C "$REPO_ROOT" worktree remove --force "$WORKTREE" 2>/dev/null || true
info "DONE — minted stage-0 at $STAGE0_PUBLISH_DIR/lyric"
info "Next: scripts/bootstrap.sh --stage 2  (reuses the minted stage-0)"
