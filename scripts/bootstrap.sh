#!/usr/bin/env bash
# bootstrap.sh — self-hosting bootstrap for the Lyric compiler
#
# Each stage produces a COMPLETE, SELF-CONSISTENT toolchain for ONE compiler
# generation; generations are never co-mingled in a shared directory.  A stage
# reads only from the previous stage and writes only to its own isolated root.
#
# Stage 0:  Acquire a SEED binary we don't yet trust — download the latest
#           self-hosted Lyric release (default), or, when that is unavailable or
#           `LYRIC_BOOTSTRAP_MINT=1`, mint the historical F# bootstrap compiler
#           from git history (`scripts/mint-stage0-fsharp.sh`).  Either way the
#           seed's own emission ABI is untrusted; stage 2 normalises it.
#           Output: `.bootstrap/stage0-publish/`.
#
# Stage 1:  The seed compiles the current true-compiler `.l` sources into a
#           RUNNABLE true compiler plus the full stdlib bundle
#           (`lyric-stdlib/lyric.full.toml`) needed to run it.  Output:
#           `.bootstrap/stage1/` (flat) + the AOT entry-point binary.  Stage 1
#           is intrinsically ABI-MIXED — its own runtime stdlib is seed-emitted
#           (non-arity-suffixed) while the code it EMITS is arity-suffixed — so
#           it is a build-only toolchain, NOT a ship/test toolchain.
#
# Stage 2:  The stage-1 true compiler rebuilds ITSELF and the FULL stdlib
#           surface into a self-consistent, isolated toolchain root
#           (`.bootstrap/stage2/{lib,bin}`): every compiler package + every
#           `Std.*` package, all arity-suffixed and mutually consistent.  THIS
#           is the toolchain everything is tested against and that ships.
#           Building it is the runnability gate: if the self-hosted emitter has
#           a bug, it surfaces HERE as a clean, specific failure (a real emitter
#           bug to fix) rather than as build-system noise.
#
# Stage 3:  Reproducibility fixpoint (diagnostic, NON-blocking) — the stage-2
#           compiler builds the stdlib bundle and its own closure twice and the
#           images must be byte-for-byte identical (`cmp`).  The self-hosted
#           emitter is deterministic by construction (fixed Module MVID in
#           lowering.l, zero PE TimeDateStamp in assembler.l, no wall-clock), so
#           this is the property a signed reproducible release depends on
#           (Q-dist-001).  See scripts/verify-reproducible-emit.sh.
#
# Usage:
#   ./scripts/bootstrap.sh              # stages 0 + 1 + 2 (build the ship/test toolchain)
#   ./scripts/bootstrap.sh --stage 0   # acquire the seed only
#   ./scripts/bootstrap.sh --stage 1   # stages 0 + 1 (bootstrap toolchain only)
#   ./scripts/bootstrap.sh --stage 2   # stages 0 + 1 + 2 (isolated self-hosted toolchain)
#   ./scripts/bootstrap.sh --stage 3   # also run the reproducibility fixpoint diagnostic
#   SKIP_CLI_BUNDLE=1 ./scripts/bootstrap.sh --stage 1  # stage 1 stops after the stdlib
#                                              bundle; the CLI closure precompile is
#                                              skipped (iterating on one compiler package).
#   SKIP_VERIFY=1 ./scripts/bootstrap.sh --stage 3      # skip the stage-3 reproducibility
#                                              fixpoint diagnostic (it is non-blocking anyway).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
STAGE0_PUBLISH_DIR="$BUILD_DIR/stage0-publish"
STAGE0_BIN="$BUILD_DIR/stage0/lyric"
STAGE1_DIR="$BUILD_DIR/stage1"
# Stage 2 is the isolated self-hosted ship/test toolchain root.  `lib/` holds the
# coherent per-package DLL set (compiler + full stdlib, all self-hosted and
# arity-suffixed); `bin/` holds the runnable binary with its stdlib co-located.
STAGE2_DIR="$BUILD_DIR/stage2"
STAGE2_LIB_DIR="$STAGE2_DIR/lib"
STAGE2_BIN_DIR="$STAGE2_DIR/bin"
# Stage 3 is the reproducibility-fixpoint scratch root (diagnostic only).
STAGE3_DIR="$BUILD_DIR/stage3"
COMPILER_DIR="$REPO_ROOT/bootstrap"
STDLIB_DIR="$REPO_ROOT/lyric-stdlib"

# AOT entry-point project + the binary path it emits.  The project links the
# compiler closure named by `-p:StageDir=<dir>`, so we point it at each stage's
# own DLL set to produce that stage's runnable binary.
AOT_PROJ="$COMPILER_DIR/src/Lyric.Cli.Aot"
BUILD_CONFIG="${BUILD_CONFIG:-Release}"
AOT_OUT="$AOT_PROJ/bin/$BUILD_CONFIG/net10.0/lyric"

# Temp base used by mktemp-style scratch dirs below.  On Unix .NET's
# GetTempPath() returns $TMPDIR when set, else "/tmp"; we mirror that so any
# helper that globs a temp dir lines up with however the toolchain was invoked.
TMP_BASE="${TMPDIR:-/tmp}"
TMP_BASE="${TMP_BASE%/}"   # strip any trailing slash so the glob is well-formed

MAX_STAGE=2
SKIP_VERIFY="${SKIP_VERIFY:-0}"
SKIP_CLI_BUNDLE="${SKIP_CLI_BUNDLE:-0}"
SKIP_COREREF_REWRITE="${SKIP_COREREF_REWRITE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --stage) MAX_STAGE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "[bootstrap] $*"; }
ok() { echo "[bootstrap] OK: $*"; }

# ---------------------------------------------------------------------------
# Download and extract self-hosted binary from latest release
# ---------------------------------------------------------------------------
try_bootstrap_from_release() {
  # Check if binary already exists (skip download if it does)
  mkdir -p "$BUILD_DIR/stage0-publish"
  if [[ -f "$BUILD_DIR/stage0-publish/lyric" ]] || [[ -f "$BUILD_DIR/stage0-publish/lyric.exe" ]] || [[ -f "$BUILD_DIR/stage0-publish/lyric.dll" ]]; then
    info "  Using cached stage0-publish binary (skipping download)"
    return 0
  fi
  # Detect platform and architecture for downloading the right binary
  local platform
  local uname_sys="$(uname -s)"
  case "$uname_sys" in
    Linux)
      case "$(uname -m)" in
        x86_64) platform="linux-x64" ;;
        aarch64) platform="linux-arm64" ;;
        *) return 1 ;;
      esac
      ;;
    Darwin)
      case "$(uname -m)" in
        x86_64) platform="osx-x64" ;;
        arm64) platform="osx-arm64" ;;
        *) return 1 ;;
      esac
      ;;
    MINGW64_NT*|MSYS_NT*|CYGWIN_NT*)
      # Windows Git Bash, MSYS2, or Cygwin
      platform="win-x64"
      ;;
    *)
      info "Unsupported platform: $uname_sys"
      return 1
      ;;
  esac

  # Check if a specific version is pinned via LYRIC_BOOTSTRAP_VERSION
  local latest_release
  if [[ -n "${LYRIC_BOOTSTRAP_VERSION:-}" ]]; then
    latest_release="${LYRIC_BOOTSTRAP_VERSION#v}"  # Strip 'v' prefix if present
    info "Using pinned bootstrap version from LYRIC_BOOTSTRAP_VERSION: v${latest_release}"
  else
    # Fetch latest non-draft release version from GitHub API
    local api_url="https://api.github.com/repos/nichobbs/lyric-lang/releases"
    local api_response
    local curl_opts=()
    # Use GITHUB_TOKEN for authentication if available (increases rate limit from 60 to 5000 req/hr)
    if [[ -n "${GITHUB_TOKEN:-}" ]]; then
      curl_opts=(-H "Authorization: token $GITHUB_TOKEN")
      info "  Using authenticated GitHub API (GITHUB_TOKEN set)"
    else
      info "  Using unauthenticated GitHub API (GITHUB_TOKEN not set, limited to 60 req/hr)"
    fi

    # Fetch API response and save to variable for debugging
    api_response=$(curl -sSL ${curl_opts[@]+"${curl_opts[@]}"} "$api_url" 2>&1)

    # Log the response (first 200 chars for debugging)
    if [[ -n "$api_response" ]]; then
      info "  API response (first 200 chars): ${api_response:0:200}"
    else
      info "  API returned empty response"
      return 1
    fi

    # Check for error responses (e.g., "message": "Bad credentials")
    if echo "$api_response" | grep -q '"message"'; then
      info "  GitHub API error response detected"
      return 1
    fi

    if command -v jq &>/dev/null; then
      # Use jq for robust JSON parsing if available.
      # Strategy: prefer non-draft releases (stable), but fall back to draft releases
      # (e.g., newly-published releases being finalized by the workflow).
      # Note: draft field defaults to false if missing.

      # First try non-draft releases
      latest_release=$(echo "$api_response" | jq -r '.[] | select((.draft // false) != true) | .tag_name | select(. != null and . != "")' 2>/dev/null | head -1)

      # If no non-draft found, fall back to the latest draft (in case a fresh release
      # is being published and not yet finalized)
      if [[ -z "$latest_release" ]]; then
        info "  No non-draft release found; checking for draft releases..."
        latest_release=$(echo "$api_response" | jq -r '.[0] | select(.tag_name != null and .tag_name != "") | .tag_name' 2>/dev/null)
      fi
    else
      # Fall back to basic grep+sed for systems without jq.
      # Try non-draft releases first
      if echo "$api_response" | grep -q '"draft": false'; then
        # Find the portion with non-draft releases and extract the first tag_name
        # Convert multiline JSON to single line, split on "}, then grep for non-draft
        latest_release=$(printf "%s" "$api_response" | tr '\n' ' ' | sed 's/"}, *"/"}\n"/g' | \
          grep '"draft": false' | head -1 | \
          sed 's/.*"tag_name": "\([^"]*\)".*/\1/')
      else
        # Fall back to the latest release (draft or not)
        info "  No non-draft release found; checking for draft releases..."
        latest_release=$(printf "%s" "$api_response" | tr '\n' ' ' | sed 's/"}, *"/"}\n"/g' | \
          head -1 | \
          sed 's/.*"tag_name": "\([^"]*\)".*/\1/')
      fi
    fi

    if [[ -z "$latest_release" ]]; then
      info "  Failed to extract release version from GitHub API response"
      info "  Full API response: $api_response"
      return 1
    fi

    latest_release="${latest_release#v}"  # Strip 'v' prefix if present
  fi

  # latest_release is now the version without 'v' prefix (e.g., "0.3.0")
  info "Using bootstrap release: v${latest_release}"

  # Construct the tag name with 'v' prefix for downloads
  local release_tag="v${latest_release}"

  # Determine archive format based on platform
  local archive_suffix
  case "$platform" in
    win-x64) archive_suffix="zip" ;;
    *) archive_suffix="tar.gz" ;;
  esac

  local archive_name="lyric-${latest_release}-${platform}.${archive_suffix}"
  local download_url="https://github.com/nichobbs/lyric-lang/releases/download/${release_tag}/${archive_name}"

  info "Bootstrapping from release: $release_tag (platform: $platform)"
  info "  Archive: $archive_name"
  info "  Download URL: $download_url"

  # Create temporary directory for download
  local temp_dir
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/lyric-release.XXXXXX")"
  trap "rm -rf '$temp_dir'" RETURN

  # Try to download the release binary
  info "  Downloading..."
  local archive_path="${temp_dir}/lyric.${archive_suffix}"
  if command -v curl &>/dev/null; then
    if curl -sSL "$download_url" -o "$archive_path" 2>/dev/null; then
      info "  Download successful"
    else
      info "  Download failed"
      return 1
    fi
  elif command -v wget &>/dev/null; then
    if wget -q "$download_url" -O "$archive_path" 2>/dev/null; then
      info "  Download successful"
    else
      info "  Download failed"
      return 1
    fi
  else
    info "  SKIP: Neither curl nor wget found"
    return 1
  fi

  # Extract to stage0-publish
  mkdir -p "$BUILD_DIR/stage0-publish"
  if [[ "$archive_suffix" == "zip" ]]; then
    if command -v unzip &>/dev/null; then
      if unzip -q "$archive_path" -d "$BUILD_DIR/stage0-publish"; then
        info "  Extraction successful"
        return 0
      else
        info "  Failed to extract zip archive (file may be corrupted or missing)"
        return 1
      fi
    else
      info "  SKIP: unzip not found (required for .zip extraction)"
      return 1
    fi
  else
    if tar -xzf "$archive_path" -C "$BUILD_DIR/stage0-publish"; then
      info "  Extraction successful"
      return 0
    else
      info "  Failed to extract tar.gz archive (file may be corrupted or missing)"
      return 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# Stage 0 — Download self-hosted binary from release
# ---------------------------------------------------------------------------
stage0() {
  mkdir -p "$BUILD_DIR/stage0-publish"
  mkdir -p "$(dirname "$STAGE0_BIN")"

  # The published release stage-0 binary is currently regressed: it mis-emits
  # >64 KB string-heap indices (truncated to 2 bytes) and generic-union case
  # TypeRefs (missing the `\`N` arity suffix), corrupting any large per-package
  # DLL — notably Lyric.Lyric.Cli, whose type names come back mangled so the AOT
  # entry-point cannot resolve `Lyric.Cli.Program`.  Both bugs are fixed in the
  # current self-hosted emitter source but are baked into the released binary,
  # so a clean checkout cannot escape them via the download.
  #
  # `scripts/mint-stage0-fsharp.sh` rebuilds the historical F# bootstrap
  # compiler (a separate emitter with neither bug) from git history and uses it
  # to produce a clean stage-0 carrying the current (fixed) self-hosted emitter.
  # Opt in with LYRIC_BOOTSTRAP_MINT=1 (set in CI until a fixed binary ships);
  # otherwise download, and fall back to minting if the download fails.  The
  # mint populates $BUILD_DIR/stage0-publish, which try_bootstrap_from_release
  # then reuses instead of downloading.
  if [[ "${LYRIC_BOOTSTRAP_MINT:-0}" == "1" ]] && \
     [[ ! -f "$BUILD_DIR/stage0-publish/lyric" ]] && \
     [[ ! -f "$BUILD_DIR/stage0-publish/lyric.dll" ]] && \
     [[ ! -f "$BUILD_DIR/stage0-publish/lyric.exe" ]]; then
    info "Stage 0: LYRIC_BOOTSTRAP_MINT=1 — minting clean stage-0 from F# history"
    FAST="${MINT_FAST:-1}" bash "$REPO_ROOT/scripts/mint-stage0-fsharp.sh" \
      || die "Stage 0: mint failed (scripts/mint-stage0-fsharp.sh)"
  fi

  # Download self-hosted binary from latest release (reuses a minted
  # stage0-publish if present), minting from F# history if the download fails.
  if ! try_bootstrap_from_release; then
    info "Stage 0: release download failed — minting clean stage-0 from F# history"
    FAST="${MINT_FAST:-1}" bash "$REPO_ROOT/scripts/mint-stage0-fsharp.sh" \
      || die "Stage 0: download failed AND mint failed (scripts/mint-stage0-fsharp.sh)"
  fi
  info "Stage 0: using self-hosted binary"

  # Publish output handling:
  #   * Linux/macOS: native executable "lyric" (no extension) + runtimeconfig.json
  #   * Windows (PowerShell): native executable "lyric.exe" + runtimeconfig.json
  #   * Windows (Git Bash): bash wrapper "lyric" + framework-dependent "lyric.dll"
  #
  # The invoke_stage0 helper checks for .dll and .exe extensions, so we copy/symlink
  # accordingly. Always copy (never symlink) to ensure Windows Git Bash wrapper works.
  if [[ -f "$BUILD_DIR/stage0-publish/lyric.exe" ]]; then
    # Windows native executable
    mkdir -p "$(dirname "$STAGE0_BIN")"
    cp "$BUILD_DIR/stage0-publish/lyric.exe" "$STAGE0_BIN.exe"
    if [[ -f "$BUILD_DIR/stage0-publish/lyric.runtimeconfig.json" ]]; then
      cp "$BUILD_DIR/stage0-publish/lyric.runtimeconfig.json" "$STAGE0_BIN.runtimeconfig.json"
      info "  copied runtimeconfig.json"
    else
      info "  WARNING: lyric.runtimeconfig.json not found in stage0-publish"
    fi
  elif [[ -f "$BUILD_DIR/stage0-publish/lyric.dll" ]]; then
    # Windows Git Bash (wrapper script) or framework-dependent DLL-only case
    cp "$BUILD_DIR/stage0-publish/lyric.dll" "$STAGE0_BIN.dll"
    # Copy the wrapper script if present (for Git Bash completeness, but we'll use the DLL)
    if [[ -f "$BUILD_DIR/stage0-publish/lyric" ]]; then
      cp "$BUILD_DIR/stage0-publish/lyric" "$STAGE0_BIN"
    fi
  elif [[ -f "$BUILD_DIR/stage0-publish/lyric" ]]; then
    # Unix native executable
    mkdir -p "$(dirname "$STAGE0_BIN")"
    cp "$BUILD_DIR/stage0-publish/lyric" "$STAGE0_BIN"
    # Copy runtime config if present (needed for self-contained apps)
    if [[ -f "$BUILD_DIR/stage0-publish/lyric.runtimeconfig.json" ]]; then
      cp "$BUILD_DIR/stage0-publish/lyric.runtimeconfig.json" "$STAGE0_BIN.runtimeconfig.json"
      info "  copied runtimeconfig.json"
    else
      info "  WARNING: lyric.runtimeconfig.json not found in stage0-publish"
    fi
  else
    die "publish did not produce a lyric binary in $BUILD_DIR/stage0-publish"
  fi

  # Copy the lib/ directory containing Lyric.Stdlib.dll and other runtime dependencies.
  # The binary resolves these at runtime via findCompiledStdlibDir(<binary>/lib).
  if [[ -d "$BUILD_DIR/stage0-publish/lib" ]]; then
    mkdir -p "$(dirname "$STAGE0_BIN")/lib"
    cp -r "$BUILD_DIR/stage0-publish/lib"/* "$(dirname "$STAGE0_BIN")/lib/" 2>/dev/null || true
    info "  copied lib/ directory with runtime dependencies"
  else
    info "  WARNING: lib/ directory not found in stage0-publish (binary may fail at runtime)"
  fi

  ok "Stage 0 complete — $STAGE0_BIN"

  # Verify the binary exists in one of its expected forms and runtimeconfig.json if needed
  if [[ -f "$STAGE0_BIN" ]]; then
    info "Stage 0 binary: $(ls -lh "$STAGE0_BIN")"
    if [[ -f "$STAGE0_BIN.runtimeconfig.json" ]]; then
      info "  with runtimeconfig.json: $(ls -lh "$STAGE0_BIN.runtimeconfig.json")"
    else
      info "  WARNING: runtimeconfig.json NOT found at $STAGE0_BIN.runtimeconfig.json"
    fi
  elif [[ -f "$STAGE0_BIN.dll" ]]; then
    info "Stage 0 DLL: $(ls -lh "$STAGE0_BIN.dll")"
    if [[ -f "$STAGE0_BIN" ]]; then
      info "Stage 0 wrapper: $(ls -lh "$STAGE0_BIN")"
    fi
  elif [[ -f "$STAGE0_BIN.exe" ]]; then
    info "Stage 0 EXE: $(ls -lh "$STAGE0_BIN.exe")"
    if [[ -f "$STAGE0_BIN.runtimeconfig.json" ]]; then
      info "  with runtimeconfig.json: $(ls -lh "$STAGE0_BIN.runtimeconfig.json")"
    else
      info "  WARNING: runtimeconfig.json NOT found at $STAGE0_BIN.runtimeconfig.json"
    fi
  else
    die "Stage 0 binary not found at $STAGE0_BIN, $STAGE0_BIN.dll, or $STAGE0_BIN.exe"
  fi
  info "stage0-publish directory contents:"
  ls -lh "$BUILD_DIR/stage0-publish/" || true
}

# ---------------------------------------------------------------------------
# Stage 1 — compile the Lyric compiler using the F# bootstrap (stage 0)
# ---------------------------------------------------------------------------
stage1() {
  info "Stage 1: compiling Lyric compiler packages with stage-0 lyric"
  mkdir -p "$STAGE1_DIR"

  # Helper to invoke stage-0, handling native binaries, EXE files, and DLLs.
  # The binary is in STAGE0_PUBLISH_DIR with its runtimeconfig.json, so we invoke it
  # from there to avoid path issues with framework-dependent apps.
  # On Windows Git Bash, dotnet publish creates a bash wrapper + DLL, so we need
  # to invoke the DLL via dotnet. On Windows proper (PowerShell), we get an EXE.
  # On Unix, we get a native executable.
  invoke_stage0() {
    local bin_path
    local actual_file

    # Check what type of file we actually have in stage0-publish
    if [[ -f "$STAGE0_PUBLISH_DIR/lyric.exe" ]]; then
      actual_file="$STAGE0_PUBLISH_DIR/lyric.exe"
    elif [[ -f "$STAGE0_PUBLISH_DIR/lyric.dll" ]]; then
      actual_file="$STAGE0_PUBLISH_DIR/lyric.dll"
    elif [[ -f "$STAGE0_PUBLISH_DIR/lyric" ]]; then
      actual_file="$STAGE0_PUBLISH_DIR/lyric"
    else
      die "Stage 0 binary not found in $STAGE0_PUBLISH_DIR (checked for .exe, .dll, and native binary)"
    fi

    bin_path="$actual_file"

    # For Windows files (EXE/DLL), convert Unix path to Windows path
    if [[ "$actual_file" == *.exe ]] || [[ "$actual_file" == *.dll ]]; then
      if command -v cygpath &>/dev/null; then
        bin_path="$(cygpath -w "$actual_file")"
      fi
      # If it's a DLL, invoke via dotnet; if it's an EXE, invoke directly
      if [[ "$actual_file" == *.dll ]]; then
        dotnet "$bin_path" "$@"
      else
        "$bin_path" "$@"
      fi
    else
      # Native binary on Unix
      "$actual_file" "$@"
    fi
  }

  # Build the stdlib bundle first (multi-package manifest).  The released
  # self-hosted stage-0 binary drives the multi-package compile through the
  # public `lyric build --manifest` command, building the [project.packages]
  # list into one `Lyric.Stdlib.dll`.  `--no-restore` because the stdlib has
  # no external dependencies.
  #
  # Use the FULL manifest (every bundleable Std.* package), NOT the historical
  # 15-package smoke set (`lyric.toml`).  Post-#4025 every Std.* reference
  # collapses to the single `Lyric.Stdlib` assembly, so a stage-1 bundle that
  # omits a CLI import (e.g. Std.File) makes the framework-dependent
  # AOT-entry binary fail to load at startup
  # (`TypeLoadException: Std.File.Program from Lyric.Stdlib`).  The full bundle
  # carries the whole CLI closure, so the stage-1 binary runs — and it matches
  # what stage 2 and stage-selfhosted-stdlib.sh build, eliminating the
  # smoke/full divergence.  The not-yet-bundleable HTTP/async packages (#4030)
  # are excluded from the manifest and emitted per-package separately.
  info "  compiling stdlib bundle"
  invoke_stage0 build --manifest "$STDLIB_DIR/lyric.full.toml" \
    -o "$STAGE1_DIR/Lyric.Stdlib.dll" --target dotnet --no-restore 2>&1 || \
    die "stdlib bundle build failed"

  if [[ "$SKIP_CLI_BUNDLE" != "1" ]]; then
    stage1_cli_bundle
  else
    info "SKIP_CLI_BUNDLE=1; skipping the CLI dependency-closure precompile"
  fi

  ok "Stage 1 complete — output in $STAGE1_DIR"
}

# ---------------------------------------------------------------------------
# Stage 1 — CLI bundle precompile (Track A, A1.2)
# ---------------------------------------------------------------------------
stage1_cli_bundle() {
  # When stage-0 was minted from the F# bootstrap compiler, the mint already
  # emitted the entire Lyric.Cli closure (per-package, CoreLib-retargeted) into
  # $STAGE1_DIR.  Those F#-emitted DLLs are the reference output for STAGE 1, the
  # ABI-mixed bootstrap toolchain.  Reuse the minted closure here; only the
  # freshly-built stdlib bundle needs its CoreLib refs retargeted (the mint
  # already retargeted the closure DLLs, and the rewrite is idempotent for those).
  #
  # This reuse is a STAGE-1 detail, not a self-host limitation.  Stage 2 — the
  # stage-1 compiler rebuilding ITSELF — now produces a fully runnable,
  # byte-for-byte reproducible toolchain (D-progress-531: stage 2 RUNS, stage 3
  # closure 101/101 DLLs + stdlib byte-identical).  The last per-package blocker
  # (#3920 / #4020) was a cross-package nullary-union-case singleton
  # mis-detection: the restored path used an arity-suffix proxy that missed the
  # non-generic `Lyric.Lexer`, so the self-emitted parser `newobj`'d keyword
  # cases that never `Object.Equals`'d the lexer's tokens and hung on
  # `opaque type` (the one item consumed via `tryEatKw`).  #4020 detects the
  # `Instance` field directly, clearing it.  Stage 1 still reuses the minted
  # closure only because it is intentionally ABI-mixed (its own runtime stdlib is
  # seed-emitted); stage 2 is the self-consistent ship/test toolchain.
  if [[ "${LYRIC_BOOTSTRAP_MINT:-0}" == "1" ]] && [[ -f "$STAGE1_DIR/Lyric.Lyric.Cli.dll" ]]; then
    info "Stage 1 (CLI bundle): reusing minted F#-emitted closure (intentional — stage 1 is the ABI-mixed bootstrap toolchain; stage 2 is the self-hosted rebuild)"
    if [[ "$SKIP_COREREF_REWRITE" != "1" ]]; then
      info "  retargeting System.Private.CoreLib refs -> public facades"
      dotnet fsi "$REPO_ROOT/scripts/rewrite-corelib-refs.fsx" "$STAGE1_DIR"/*.dll \
        > "$BUILD_DIR/rewrite-corelib-refs.log" 2>&1 || \
        die "stage-1 CLI bundle: corelib-ref rewrite failed"
    fi
    ok "Stage 1 CLI bundle complete — minted F#-emitted closure in $STAGE1_DIR"
    return
  fi

  info "Stage 1 (CLI bundle): precompiling Lyric.Cli + transitive deps"

  local driver_dir="$BUILD_DIR/stage1-cli-driver"
  rm -rf "$driver_dir"
  mkdir -p "$driver_dir"

  cat > "$driver_dir/driver.l" <<'EOF'
// Auto-generated driver for the bootstrap CLI-bundle precompile.
// Importing Lyric.Cli makes the per-package emitter discover and emit the
// whole compiler-package closure (plus its stdlib import closure).
package Lyric.CliBundle
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Unit { }
EOF

  # Emit the driver's transitive import closure as per-package DLLs straight
  # into the stage-1 output dir via the self-hosted per-package emitter
  # (`emitPerPackageClosure`).  This replaces the retired F# `--internal-build`
  # + /tmp-cache-harvest path: the released self-hosted binary emits each
  # Lyric.* / Msil.* / Jvm.* / Std.* package as its own DLL directly.  Do NOT
  # pin LYRIC_STD_PATH at the bundle dir here — the emitter must resolve every
  # package from `lyric-stdlib/std` source to recompile the whole closure.
  invoke_stage0 --internal-perpackage-build "$driver_dir/driver.l" \
    "$STAGE1_DIR" --target dotnet 2>&1 || \
    die "stage-1 CLI-bundle per-package emit failed"

  [[ -f "$STAGE1_DIR/Lyric.Lyric.Cli.dll" ]] || \
    die "stage-1 CLI bundle: Lyric.Lyric.Cli.dll not found in $STAGE1_DIR after emit"
  local copied
  copied="$(ls "$STAGE1_DIR"/*.dll 2>/dev/null | wc -l)"

  if [[ "$SKIP_COREREF_REWRITE" != "1" ]]; then
    info "  retargeting System.Private.CoreLib refs -> public facades"
    dotnet fsi "$REPO_ROOT/scripts/rewrite-corelib-refs.fsx" "$STAGE1_DIR"/*.dll \
      > "$BUILD_DIR/rewrite-corelib-refs.log" 2>&1 || \
      die "stage-1 CLI bundle: corelib-ref rewrite failed"
  else
    info "SKIP_COREREF_REWRITE=1; leaving stage-1 DLLs with raw CoreLib refs"
  fi

  ok "Stage 1 CLI bundle complete — Lyric.Lyric.Cli.dll + $((copied - 1)) deps in $STAGE1_DIR"
}

# ---------------------------------------------------------------------------
# AOT-link a runnable `lyric` binary from a given stage's compiler closure.
# `$1` is the directory holding that stage's `Lyric.*.dll` set.  The AOT
# project's <Reference> glob pulls in exactly that closed set.
# ---------------------------------------------------------------------------
build_aot_binary() {
  local stage_dir="$1"
  local log="$2"
  dotnet build "$AOT_PROJ" --configuration "$BUILD_CONFIG" --no-incremental \
    -p:StageDir="$stage_dir" > "$log" 2>&1 \
    || die "AOT entry-point build failed against $stage_dir (see $log)"
  [[ -x "$AOT_OUT" ]] || die "AOT lyric binary not found at $AOT_OUT after build"
}

# ---------------------------------------------------------------------------
# Stage 2 — the stage-1 true compiler rebuilds ITSELF + the FULL stdlib into an
# isolated, self-consistent ship/test toolchain (`.bootstrap/stage2/{lib,bin}`).
#
# A single `--internal-perpackage-build` over a driver that imports the whole
# compiler (`Lyric.Cli`) plus every PUBLIC `Std.*` package emits the entire
# closure — compiler packages and stdlib — as per-package DLLs, all
# arity-suffixed and mutually consistent.  That coherence is what eliminates the
# seed-vs-self-hosted ABI split (and with it the userlib/selfhosted staging
# hacks): the stage-2 stdlib a consumer links is emitted by the SAME compiler,
# in the SAME pass, as the references that point at it.
#
# Building the toolchain is the runnability gate.  When the self-hosted emitter
# has a bug, the per-package emit may still succeed but the AOT-linked binary
# faults at startup (e.g. a cross-package generic TypeRef that does not match
# its definition).  We report that as the runnability signal and DO NOT fail the
# stage — the isolated toolchain exists precisely so the bug surfaces cleanly.
# ---------------------------------------------------------------------------
build_stage2() {
  info "Stage 2: building the self-hosted ship/test toolchain (true builds true)"

  # 1. AOT-link the stage-1 true compiler from the freshly-built stage-1 DLLs.
  #    `dotnet build` produces a framework-dependent app (`lyric` apphost +
  #    `lyric.dll` + its DLLs), so it is run in place from its build directory —
  #    the whole directory, not the bare apphost, is the relocatable unit.
  info "  AOT-linking the stage-1 true compiler from $STAGE1_DIR"
  build_aot_binary "$STAGE1_DIR" "$BUILD_DIR/aot-stage1.log"

  # 2. Wipe the stage-2 root so no prior generation's artefacts survive.
  rm -rf "$STAGE2_DIR"
  mkdir -p "$STAGE2_LIB_DIR" "$STAGE2_BIN_DIR"

  # 3. Emit the whole compiler + full stdlib closure, per-package, in one pass,
  #    via the stage-1 binary (run in place at $AOT_OUT).
  local driver_dir="$BUILD_DIR/stage2-driver"
  rm -rf "$driver_dir"; mkdir -p "$driver_dir"
  {
    echo "package SelfHostedStage2Toolchain"
    echo "import Lyric.Cli"
    # Public Std.* packages from the full manifest; the `*Host` kernel
    # boundaries are pulled in transitively, not imported directly.
    sed -n 's/^"\(Std\.[A-Za-z0-9.]*\)".*/\1/p' "$STDLIB_DIR/lyric.full.toml" \
      | grep -v 'Host$' \
      | while read -r pkg; do echo "import $pkg"; done
    echo "func main(): Unit { }"
  } > "$driver_dir/driver.l"

  info "  emitting compiler + full stdlib closure (per-package) -> $STAGE2_LIB_DIR"
  "$AOT_OUT" --internal-perpackage-build "$driver_dir/driver.l" \
    "$STAGE2_LIB_DIR" --target dotnet > "$BUILD_DIR/stage2-emit.log" 2>&1 \
    || { cat "$BUILD_DIR/stage2-emit.log" >&2;
         die "stage-2 closure emit FAILED — see $BUILD_DIR/stage2-emit.log"; }
  [[ -f "$STAGE2_LIB_DIR/Lyric.Lyric.Cli.dll" ]] \
    || die "stage-2 emit produced no Lyric.Lyric.Cli.dll in $STAGE2_LIB_DIR"
  local n
  n="$(ls "$STAGE2_LIB_DIR"/*.dll 2>/dev/null | wc -l | tr -d ' ')"
  ok "  emitted $n self-hosted DLLs (compiler + stdlib)"

  # 3b. Build the SINGLE full stdlib bundle (`Lyric.Stdlib.dll`).  Post-collapse
  #     (D111) every `Std.*` reference — in the compiler closure above and in any
  #     user program — resolves to the single `Lyric.Stdlib` assembly identity, so
  #     this one bundle (carrying every package from `lyric.full.toml`) is what
  #     satisfies those references at runtime.  The per-package
  #     `Lyric.Stdlib.*.dll` the closure pass emitted are then removed so the
  #     output directory holds exactly one authoritative stdlib assembly.
  info "  building the single full stdlib bundle -> $STAGE2_LIB_DIR/Lyric.Stdlib.dll"
  "$AOT_OUT" build --manifest "$STDLIB_DIR/lyric.full.toml" \
    -o "$STAGE2_LIB_DIR/Lyric.Stdlib.dll" --target dotnet --no-restore \
    > "$BUILD_DIR/stage2-stdlib.log" 2>&1 \
    || { cat "$BUILD_DIR/stage2-stdlib.log" >&2;
         die "stage-2 single stdlib bundle build FAILED — see $BUILD_DIR/stage2-stdlib.log"; }
  [[ -f "$STAGE2_LIB_DIR/Lyric.Stdlib.dll" ]] \
    || die "stage-2 single stdlib bundle not produced in $STAGE2_LIB_DIR"
  # Drop the now-redundant per-package stdlib DLLs (the `.` after `Lyric.Stdlib`
  # matches `Lyric.Stdlib.Core.dll` etc. but not the bundle `Lyric.Stdlib.dll`).
  shopt -s nullglob
  rm -f "$STAGE2_LIB_DIR"/Lyric.Stdlib.*.dll
  shopt -u nullglob
  ok "  built single Lyric.Stdlib.dll bundle"

  # 4. AOT-link the stage-2 binary from the self-hosted closure.
  #    The stage-1 binary ($AOT_OUT) was compiled from the current sources and
  #    supports `lyric build --release-from-dll`.  Use it here so the stage-2
  #    native binary is produced entirely by the self-hosted Lyric toolchain —
  #    no C# build step is needed.  The binary lands directly in $STAGE2_BIN_DIR.
  info "  AOT-linking the stage-2 binary via lyric build --release-from-dll"
  mkdir -p "$STAGE2_BIN_DIR"
  "$AOT_OUT" build --release-from-dll "$STAGE2_LIB_DIR/Lyric.Lyric.Cli.dll" \
    --extra-refs-dir "$STAGE2_LIB_DIR" -o "$STAGE2_BIN_DIR/lyric" \
    > "$BUILD_DIR/aot-stage2.log" 2>&1 \
    || { cat "$BUILD_DIR/aot-stage2.log" >&2
         die "stage-2 AOT build FAILED — see $BUILD_DIR/aot-stage2.log"; }
  [[ -x "$STAGE2_BIN_DIR/lyric" ]] \
    || die "stage-2 lyric binary not found at $STAGE2_BIN_DIR/lyric"

  # 5. Runnability smoke — NON-FATAL.  A self-hosted-emitter bug surfaces here
  #    as a clean, specific failure rather than as build noise.
  info "  runnability smoke: stage-2 lyric --version"
  if LYRIC_STDLIB_BIN="$STAGE2_LIB_DIR" "$STAGE2_BIN_DIR/lyric" --version \
        > "$BUILD_DIR/stage2-smoke.log" 2>&1; then
    ok "Stage 2 toolchain RUNS — $(head -1 "$BUILD_DIR/stage2-smoke.log")"
  else
    info "Stage 2 toolchain BUILT but does NOT yet RUN — self-hosted emitter blocker:"
    grep -m1 -E "Exception|Could not load|[Ee]rror" "$BUILD_DIR/stage2-smoke.log" \
      | sed 's/^/    /' || true
    info "  full log: $BUILD_DIR/stage2-smoke.log"
    info "  this is the runnability signal — fix the emitter bug, not the build."
  fi
  ok "Stage 2 complete — isolated self-hosted toolchain in $STAGE2_DIR"
}

# ---------------------------------------------------------------------------
# Stage 3 — reproducibility fixpoint (diagnostic, NON-blocking)
#
# The self-hosted emitter is deterministic by construction, so the stage-2
# toolchain must emit byte-identical images run-to-run.  We verify that by
# building the stdlib bundle and the whole compiler closure TWICE through the
# stage-2 binary and comparing with an exact `cmp`
# (`scripts/verify-reproducible-emit.sh`).  This is the property a signed,
# reproducible release depends on (Q-dist-001) — but under the runnability-first
# model it is a diagnostic, NOT a gate: a difference is reported, never fatal.
# When the stage-2 toolchain is not yet runnable (a self-hosted emitter blocker
# surfaced in stage 2), the fixpoint cannot run and is reported as pending.
# ---------------------------------------------------------------------------
stage3() {
  if [[ "$SKIP_VERIFY" == "1" ]]; then
    info "SKIP_VERIFY=1; skipping the stage-3 reproducibility fixpoint"
    return 0
  fi
  info "Stage 3: reproducibility fixpoint (diagnostic, non-blocking)"
  local s2bin="$STAGE2_BIN_DIR/lyric"
  if [[ ! -x "$s2bin" ]]; then
    info "  stage-2 binary missing ($s2bin); run stage 2 first — skipping"
    return 0
  fi
  if ! LYRIC_STDLIB_BIN="$STAGE2_LIB_DIR" "$s2bin" --version >/dev/null 2>&1; then
    info "  fixpoint PENDING: the stage-2 toolchain is not yet runnable"
    info "  (resolve the self-hosted emitter blocker reported by stage 2 first)"
    return 0
  fi
  rm -rf "$STAGE3_DIR"; mkdir -p "$STAGE3_DIR"
  
  local rc_manifest=0
  LYRIC_STDLIB_BIN="$STAGE2_LIB_DIR" \
    "$REPO_ROOT/scripts/verify-reproducible-emit.sh" \
    manifest "$s2bin" "$STDLIB_DIR/lyric.full.toml" || rc_manifest=$?

  if [[ $rc_manifest -ne 0 ]]; then
    die "Stage 3: manifest reproducibility check failed (exit $rc_manifest). Exit 3 = reproducibility diff."
  fi

  local rc_closure=0
  LYRIC_STDLIB_BIN="$STAGE2_LIB_DIR" \
    "$REPO_ROOT/scripts/verify-reproducible-emit.sh" \
    closure "$s2bin" || rc_closure=$?

  if [[ $rc_closure -ne 0 ]]; then
    die "Stage 3: closure reproducibility check failed (exit $rc_closure). Exit 3 = reproducibility diff."
  fi

  if [[ $rc_manifest -eq 0 && $rc_closure -eq 0 ]]; then
    ok "Stage 3: self-hosted emit is byte-for-byte reproducible (fixpoint holds)"
  else
    info "Stage 3: reproducibility fixpoint DIFFERS — reported, non-blocking (Q-dist-001)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

stage0
[[ $MAX_STAGE -ge 1 ]] && stage1
[[ $MAX_STAGE -ge 2 ]] && build_stage2
[[ $MAX_STAGE -ge 3 ]] && stage3

info "Bootstrap finished (max stage: $MAX_STAGE)"
