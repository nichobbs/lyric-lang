#!/usr/bin/env bash
# bootstrap.sh — self-hosting bootstrap for the Lyric compiler
#
# Stage 0:  Download the latest self-hosted Lyric binary from GitHub releases
#           (by default), or build the F# bootstrap compiler (if BOOTSTRAP_FROM_RELEASE=0).
#           The F# bootstrap is on a deletion schedule; released binaries are preferred.
#
# Stage 1:  Use stage-0 lyric to compile the Lyric-written compiler packages
#           (stdlib, Lyric.Lexer, Lyric.Parser, Lyric.TypeChecker,
#           Lyric.ModeChecker, Lyric.ContractElaborator, Msil.Codegen,
#           Msil.Lowering, Msil.Bridge) into DLLs.  Then drive the F#
#           emitter via a tiny `import Lyric.Cli` driver so it precompiles
#           the full CLI dependency closure (cli/ + ~25 Lyric packages)
#           and copies the artefacts into `.bootstrap/stage1/`.  These are
#           the DLLs Track A's AOT entry-point project will reference.
#
# Stage 2:  Reproducibility verification: build the full self-hosted stdlib
#           bundle (`lyric-stdlib/lyric.full.toml`) TWICE via the AOT
#           `lyric` binary and assert the two images are byte-for-byte identical
#           with an exact `cmp`.  The self-hosted emitter is deterministic by
#           construction — fixed Module MVID (lowering.l) and zero PE TimeDateStamp
#           (assembler.l), no wall-clock baked into any heap or resource.
#           This is the property a signed, reproducible release depends on (Q-dist-001);
#           a regression here FAILS the build.  See scripts/verify-reproducible-emit.sh.
#
# Usage:
#   ./scripts/bootstrap.sh              # all stages; downloads released binary for stage 0
#   ./scripts/bootstrap.sh --stage 0   # download released binary only
#   ./scripts/bootstrap.sh --stage 1   # stages 0 + 1
#   ./scripts/bootstrap.sh --stage 2   # all stages incl. reproducibility gate
#   SKIP_VERIFY=1 ./scripts/bootstrap.sh  # skip ALL of stage-2 verification
#   SKIP_CLI_BUNDLE=1 ./scripts/bootstrap.sh  # stage 1 stops after the compiler-package
#                                              loop; the CLI bundle step is skipped.
#                                              Useful when iterating on a single
#                                              compiler package.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
STAGE0_PUBLISH_DIR="$BUILD_DIR/stage0-publish"
STAGE0_BIN="$BUILD_DIR/stage0/lyric"
STAGE1_DIR="$BUILD_DIR/stage1"
STAGE2_DIR="$BUILD_DIR/stage2"
COMPILER_DIR="$REPO_ROOT/bootstrap"
STDLIB_DIR="$REPO_ROOT/lyric-stdlib"

# Temp base used by the F# emitter's per-process stdlib cache
# (`Emitter.fs::stdlibCacheDir` → `Path.GetTempPath()`).  On Unix .NET's
# GetTempPath() returns $TMPDIR when set, else "/tmp".  We mirror that exactly
# so the CLI-bundle snapshot below globs the same directory the emitter writes
# to — otherwise a non-/tmp $TMPDIR makes the snapshot miss the cache and the
# build dies (this is why callers previously had to force `TMPDIR=/tmp`).
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

  # Fetch latest non-draft release version from GitHub API
  local latest_release
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
  api_response=$(curl -sSL "${curl_opts[@]}" "$api_url" 2>&1)

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
    # Use jq for robust JSON parsing if available
    # Find the first non-draft release with a tag_name
    # Note: draft field defaults to false if missing
    latest_release=$(echo "$api_response" | jq -r '.[] | select((.draft // false) != true) | .tag_name | select(. != null and . != "")' 2>/dev/null | head -1)
  else
    # Fall back to basic grep+sed for systems without jq
    # Look for "draft": false, then extract the tag_name from that release block
    # Use a multi-line approach: find the line with draft:false, then search backward/forward for tag_name
    if echo "$api_response" | grep -q '"draft": false'; then
      # Find the portion with non-draft releases and extract the first tag_name
      # Convert multiline JSON to single line, split on "}, then grep for non-draft
      latest_release=$(printf "%s" "$api_response" | tr '\n' ' ' | sed 's/"}, *"/"}\n"/g' | \
        grep '"draft": false' | head -1 | \
        sed 's/.*"tag_name": "\([^"]*\)".*/\1/')
    fi
  fi

  if [[ -z "$latest_release" ]]; then
    info "  Failed to extract release version from GitHub API response"
    info "  Full API response: $api_response"
    return 1
  fi

  # Strip 'v' prefix from tag if present (v0.1.0 -> 0.1.0)
  local version="${latest_release#v}"
  info "Detected latest non-draft release: $latest_release (version: $version)"

  # Construct the tag name (add 'v' prefix for the tag, keep version for file names)
  local latest_release="v${version}"

  # Determine archive format based on platform
  local archive_suffix
  case "$platform" in
    win-x64) archive_suffix="zip" ;;
    *) archive_suffix="tar.gz" ;;
  esac

  local archive_name="lyric-${version}-${platform}.${archive_suffix}"
  local download_url="https://github.com/nichobbs/lyric-lang/releases/download/${latest_release}/${archive_name}"

  info "Bootstrapping from release: $latest_release (platform: $platform)"
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

  # Download self-hosted binary from latest release (F# bootstrap is deleted)
  if ! try_bootstrap_from_release; then
    die "Stage 0: failed to download self-hosted binary from GitHub releases (F# bootstrap no longer available)"
  fi
  info "Stage 0: using self-hosted binary from release"

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
  # public `lyric build --manifest` command, which reads `lyric.toml` and
  # builds the [project.packages] list into one DLL.  `--no-restore` because
  # the stdlib has no external dependencies.
  info "  compiling stdlib bundle"
  invoke_stage0 build --manifest "$STDLIB_DIR/lyric.toml" \
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
# Retarget System.Private.CoreLib refs in a directory's DLLs to the public
# facades (so the AOT linker / framework loader can resolve them).
rewrite_corelib_refs() {
  local dir="$1" log="$2"
  if [[ "$SKIP_COREREF_REWRITE" == "1" ]]; then
    info "SKIP_COREREF_REWRITE=1; leaving DLLs in $dir with raw CoreLib refs"
    return 0
  fi
  info "  retargeting System.Private.CoreLib refs -> public facades ($dir)"
  dotnet fsi "$REPO_ROOT/scripts/rewrite-corelib-refs.fsx" "$dir"/*.dll \
    > "$log" 2>&1 || die "corelib-ref rewrite failed for $dir (see $log)"
}

# Run a freshly-built minimal bootstrap compiler binary (lyric apphost or DLL).
run_boot_bin() {
  local bin_dir="$1"; shift
  if [[ -x "$bin_dir/lyric" ]]; then
    "$bin_dir/lyric" "$@"
  elif [[ -f "$bin_dir/lyric.dll" ]]; then
    dotnet "$bin_dir/lyric.dll" "$@"
  else
    die "minimal bootstrap compiler binary not found in $bin_dir"
  fi
}

# Stage 1 CLI bundle — TWO-PHASE self-host.
#
# The full Lyric.Cli dispatcher references every subcommand package, so its
# emitted assembly's string heap is irreducibly >64 KB.  The legacy stage-0
# emitter truncates string-heap indices past 64 KB, so it CANNOT emit a correct
# full dispatcher.  Instead:
#
#   Phase 1   stage-0 emits the *minimal* closure (Lyric.CliBootstrap: build +
#             internal per-package emit).  That closure — including the entire
#             front-end and back-end — is wholly under 64 KB, so stage-0 emits
#             it correctly.
#   Phase 1a  Build a framework-dependent `lyric` binary from the minimal
#             closure (entry = Lyric.CliBootstrap.Program.main).  This binary
#             carries the heap-correct emitter.
#   Phase 1b  Run that binary to re-emit the FULL Lyric.Cli closure (incl. the
#             >64 KB dispatcher) into STAGE1_DIR — now correct.
stage1_cli_bundle() {
  info "Stage 1 (CLI bundle): two-phase self-host (minimal entry -> full closure)"

  local driver_dir="$BUILD_DIR/stage1-cli-driver"
  rm -rf "$driver_dir"
  mkdir -p "$driver_dir"

  cat > "$driver_dir/driver.l" <<'EOF'
// Auto-generated driver for the bootstrap CLI-bundle precompile (full closure).
// Importing Lyric.Cli makes the per-package emitter discover and emit the
// whole compiler-package closure (plus its stdlib import closure).
package Lyric.CliBundle
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Unit { }
EOF

  cat > "$driver_dir/bootdriver.l" <<'EOF'
// Auto-generated driver for the bootstrap CLI-bundle phase 1 (minimal closure).
// Lyric.CliBootstrap is the minimal entry (build + internal per-package emit);
// its closure includes the full front-end/back-end but stays under 64 KB.
package Lyric.CliBootstrapBundle
import Lyric.CliBootstrap
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Unit { }
EOF

  local stage1_min="$BUILD_DIR/stage1-min"
  rm -rf "$stage1_min"
  mkdir -p "$stage1_min"

  # Phase 1: stage-0 emits the minimal closure (all DLLs < 64 KB -> correct).
  # Do NOT pin LYRIC_STD_PATH — the emitter must resolve every package from
  # lyric-stdlib/std source to recompile the whole closure.
  info "  phase 1: stage-0 emits minimal bootstrap closure -> $stage1_min"
  invoke_stage0 --internal-perpackage-build "$driver_dir/bootdriver.l" \
    "$stage1_min" --target dotnet 2>&1 || \
    die "stage-1 phase 1 (minimal closure) per-package emit failed"
  [[ -f "$stage1_min/Lyric.Lyric.CliBootstrap.dll" ]] || \
    die "stage-1 phase 1: Lyric.Lyric.CliBootstrap.dll not found in $stage1_min after emit"
  rewrite_corelib_refs "$stage1_min" "$BUILD_DIR/rewrite-corelib-refs-min.log"

  # Phase 1a: build the minimal (heap-correct) compiler binary.  A framework-
  # dependent build is enough — the binary only re-emits the full closure once.
  local aot_proj="$COMPILER_DIR/src/Lyric.Cli.Aot"
  local boot_bin_dir="$BUILD_DIR/stage1-bootbin"
  rm -rf "$boot_bin_dir"
  mkdir -p "$boot_bin_dir"
  info "  phase 1a: building minimal bootstrap compiler binary"
  dotnet build "$aot_proj" --configuration Release --no-incremental \
    -p:DefineConstants=BOOTSTRAP_ENTRY -p:StageDir="$stage1_min" -p:PublishAot=false \
    -o "$boot_bin_dir" \
    > "$BUILD_DIR/bootbin-build.log" 2>&1 || \
    die "stage-1 phase 1a: minimal bootstrap compiler build failed (see $BUILD_DIR/bootbin-build.log)"

  # Phase 1b: the heap-correct minimal compiler re-emits the FULL closure
  # (including the >64 KB Lyric.Cli dispatcher) correctly into STAGE1_DIR.
  info "  phase 1b: minimal compiler re-emits full Lyric.Cli closure -> $STAGE1_DIR"
  run_boot_bin "$boot_bin_dir" --internal-perpackage-build "$driver_dir/driver.l" \
    "$STAGE1_DIR" --target dotnet 2>&1 || \
    die "stage-1 phase 1b (full closure) per-package emit failed"

  [[ -f "$STAGE1_DIR/Lyric.Lyric.Cli.dll" ]] || \
    die "stage-1 CLI bundle: Lyric.Lyric.Cli.dll not found in $STAGE1_DIR after phase 1b"
  local copied
  copied="$(ls "$STAGE1_DIR"/*.dll 2>/dev/null | wc -l)"

  rewrite_corelib_refs "$STAGE1_DIR" "$BUILD_DIR/rewrite-corelib-refs.log"

  ok "Stage 1 CLI bundle complete — Lyric.Lyric.Cli.dll + $((copied - 1)) deps in $STAGE1_DIR"
}

compare_stage1_stage2_dlls() {
  local f1="$1"
  local f2="$2"
  local python_bin
  python_bin="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
  if [[ -z "$python_bin" ]]; then
    die "python3 or python is required for the stage-2 reproducibility comparison"
  fi
  "$python_bin" - "$f1" "$f2" <<'PY' >/dev/null
# Precisely normalize the INTRINSIC IDENTITY fields of two .NET PE/ECMA-335
# images before byte-comparing them, by parsing the PE + metadata layout
# rather than guessing at "16-byte differing runs".  This avoids the
# false-positive failure mode of a heuristic mask (a run can split when two
# random GUIDs coincidentally share a byte) AND the false-negative risk of
# masking a real diff that merely happens to be 16 bytes long.
#
# Fields zeroed (located, not guessed):
#   * PE COFF TimeDateStamp (4 bytes in the COFF file header).
#   * PE optional-header CheckSum (4 bytes).
#   * The Module MVID — the first 16-byte GUID in the #GUID metadata heap,
#     reached via the CLI header -> metadata root -> stream table.
#
# Everything else is compared byte-for-byte.  In particular a genuine
# nondeterminism such as the F# stage-0 emitter's `build_date` wall-clock
# (embedded in the `Lyric.SdkVersion` resource of the bundle) is NOT masked
# and will surface as a real difference — which is the intended behaviour for
# this informational stage-0 diagnostic.
from pathlib import Path
import sys

def u16(b, o): return int.from_bytes(b[o:o+2], 'little')
def u32(b, o): return int.from_bytes(b[o:o+4], 'little')

def identity_regions(b):
    """Return [(offset, length), ...] for TimeDateStamp, CheckSum, MVID."""
    regions = []
    if b[0:2] != b'MZ':
        return regions
    pe = u32(b, 0x3c)
    if b[pe:pe+4] != b'PE\x00\x00':
        return regions
    coff = pe + 4
    # COFF header: Machine[2], NumberOfSections[2], TimeDateStamp[4], ...
    regions.append((coff + 4, 4))                 # COFF TimeDateStamp
    num_sections = u16(b, coff + 2)
    opt_size = u16(b, coff + 16)
    opt = coff + 20
    magic = u16(b, opt)
    regions.append((opt + 64, 4))                 # optional-header CheckSum
    # Data directories: PE32 -> dirs at opt+96, PE32+ -> dirs at opt+112.
    dd = opt + (96 if magic == 0x10b else 112)
    cli_rva = u32(b, dd + 14 * 8)                  # data dir 14 = CLI header
    if cli_rva == 0:
        return regions
    sections = opt + opt_size
    def rva_to_off(rva):
        for i in range(num_sections):
            s = sections + i * 40
            va = u32(b, s + 12)
            vsz = u32(b, s + 8)
            rawsz = u32(b, s + 16)
            raw = u32(b, s + 20)
            if va <= rva < va + max(vsz, rawsz):
                return raw + (rva - va)
        return None
    cli = rva_to_off(cli_rva)
    if cli is None:
        return regions
    md = rva_to_off(u32(b, cli + 8))              # CLI header -> Metadata RVA
    if md is None or b[md:md+4] != b'BSJB':
        return regions
    ver_len = u32(b, md + 12)
    p = md + 16 + ((ver_len + 3) // 4 * 4)
    p += 2                                         # flags
    n_streams = u16(b, p); p += 2
    for _ in range(n_streams):
        s_off = u32(b, p); p += 4
        u32(b, p); p += 4                          # stream size (unused)
        name_start = p
        while b[p] != 0:
            p += 1
        name = b[name_start:p]
        p += 1
        while (p - name_start) % 4 != 0:           # pad name to 4-byte boundary
            p += 1
        if name == b'#GUID':
            # The module Mvid is GUID index 1 = the first 16 bytes of the heap.
            regions.append((md + s_off, 16))
            break
    return regions

f1_path = Path(sys.argv[1]); f2_path = Path(sys.argv[2])
f1 = bytearray(f1_path.read_bytes())
f2 = bytearray(f2_path.read_bytes())
if len(f1) != len(f2):
    print(f"[compare_dlls] size mismatch: {len(f1)} vs {len(f2)} bytes in {f1_path.name}", file=sys.stderr)
    sys.exit(1)

for buf in (f1, f2):
    for off, length in identity_regions(buf):
        for i in range(off, off + length):
            if 0 <= i < len(buf):
                buf[i] = 0

if f1 != f2:
    sys.exit(1)
sys.exit(0)
PY
}

# ---------------------------------------------------------------------------
# Stage 2 (a) — trust-anchor reproducibility gate (STRICT)
#
# Build two corpora TWICE through the self-hosted MSIL backend and assert each
# is byte-for-byte identical: (i) the full stdlib bundle, and (ii) the WHOLE
# Lyric.Cli compiler closure (every Lyric.* / Msil.* / Jvm.* package + its
# stdlib import closure).  This is the property a signed, reproducible release
# depends on (Q-dist-001).  The self-hosted emitter is deterministic by
# construction, so this passes with an exact `cmp` — no normalization — and a
# regression FAILS the build.
# ---------------------------------------------------------------------------
verify_selfhosted_reproducible() {
  info "Stage 2 (a): self-hosted reproducibility gate (STRICT)"

  # The AOT entry-point binary routes `--target dotnet` through the self-hosted
  # Msil.Bridge.  It embeds the stage-1 DLLs at C#-build time, so rebuild it
  # (clean) now that stage 1 has just produced fresh outputs.
  # Honour $BUILD_CONFIG (CI's convention) so the binary path matches however
  # the AOT project was configured; default to Release for standalone runs
  # (stage 0 publishes Release).
  local build_config="${BUILD_CONFIG:-Release}"
  local aot_proj="$COMPILER_DIR/src/Lyric.Cli.Aot"
  local aot_bin="$aot_proj/bin/$build_config/net10.0/lyric"
  info "  building AOT entry-point (Lyric.Cli.Aot, $build_config) against the fresh stage-1 DLLs"
  dotnet build "$aot_proj" --configuration "$build_config" --no-incremental \
    > "$BUILD_DIR/aot-build.log" 2>&1 || \
    die "AOT entry-point build failed (see $BUILD_DIR/aot-build.log)"
  [[ -x "$aot_bin" ]] || die "AOT lyric binary not found at $aot_bin after build"

  # (i) Stdlib bundle: build lyric.full.toml twice; the single output must be
  # byte-identical.
  "$REPO_ROOT/scripts/verify-reproducible-emit.sh" \
    manifest "$aot_bin" "$STDLIB_DIR/lyric.full.toml" || \
    die "self-hosted reproducibility gate FAILED — the stdlib bundle is not byte-stable"

  # (ii) Whole compiler: self-host-compile the entire Lyric.Cli closure twice;
  # every emitted DLL must be byte-identical.  This extends the reproducible
  # corpus from the stdlib to the entire self-hosted compiler.
  "$REPO_ROOT/scripts/verify-reproducible-emit.sh" \
    closure "$aot_bin" || \
    die "self-hosted reproducibility gate FAILED — the compiler closure is not byte-stable"

  ok "Self-hosted emit is byte-for-byte reproducible (trust-anchor gate passed)"
}

# ---------------------------------------------------------------------------
# Stage 2 (b) — stage-0 reproducibility diagnostic (INFORMATIONAL)
#
# Reproduce the F# stage-0 CLI-bundle precompile and compare the stage-1 and
# stage-2 DLLs after precisely normalizing the intrinsic identity fields (MVID,
# PE timestamp, checksum).  The F# emitter is non-reproducible by design (it
# bakes a `build_date` wall-clock into the bundle's `Lyric.SdkVersion`) and is
# frozen on a deletion schedule, so this is reported but NEVER fatal — it
# tracks stage-0 drift until the F# path is deleted.
# ---------------------------------------------------------------------------
stage2() {
  if [[ "$SKIP_VERIFY" == "1" ]]; then
    info "SKIP_VERIFY=1; skipping all stage-2 reproducibility verification"
    return 0
  fi

  # (a) The real gate: the self-hosted emitter must be byte-stable.
  verify_selfhosted_reproducible

  # (b) Informational stage-0 diagnostic.
  info "Stage 2 (b): stage-0 reproducibility diagnostic (informational)"

  mkdir -p "$STAGE2_DIR"

  # First, compile the stdlib bundle via the stage-0 binary so we
  # produce the top-level Lyric.Stdlib.dll the stage-1 bundle contains.
  info "  compiling stdlib bundle (stage-0 path)"
  LYRIC_STD_PATH="$STAGE1_DIR" \
    "$STAGE0_BIN" build --manifest "$STDLIB_DIR/lyric.toml" \
    -o "$STAGE2_DIR/Lyric.Stdlib.dll" --target dotnet --no-restore 2>&1 || \
    die "stage-2 stdlib bundle build failed"

  # Re-run the same CLI-bundle precompile the stage-1 step used (identical
  # driver, including the direct Std.Testing.Mocking import) so the two bundles
  # contain exactly the same set of DLLs and the comparison is apples-to-apples.
  local driver_dir="$BUILD_DIR/stage2-cli-driver"
  rm -rf "$driver_dir"
  mkdir -p "$driver_dir"

  cat > "$driver_dir/driver.l" <<'EOF'
// Auto-generated driver for the stage-2 CLI-bundle precompile.
// Mirrors the stage-1 driver exactly (same import closure) so the stage-1 vs
// stage-2 DLL sets line up one-to-one.
package Lyric.CliBundleStage2
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Unit { }
EOF

  # Emit the closure as per-package DLLs straight into the stage-2 dir via the
  # self-hosted per-package emitter — mirroring the stage-1 step.  As in stage 1,
  # do NOT pin LYRIC_STD_PATH: the emitter resolves every package from source.
  # The entry driver package itself is not emitted, only its closure, so the
  # differing driver package name vs stage 1 does not affect the DLL set.
  "$STAGE0_BIN" --internal-perpackage-build "$driver_dir/driver.l" \
    "$STAGE2_DIR" --target dotnet 2>&1 || \
    die "stage-2 CLI-bundle per-package emit failed"

  local copied
  copied="$(ls "$STAGE2_DIR"/*.dll 2>/dev/null | wc -l)"
  info "  emitted $copied DLLs into $STAGE2_DIR"

  # Retarget System.Private.CoreLib refs -> public facades so the stage-2
  # outputs match the stage-1 rewrite step.
  if [[ "$SKIP_COREREF_REWRITE" != "1" ]]; then
    info "  retargeting System.Private.CoreLib refs -> public facades (stage-2)"
    dotnet fsi "$REPO_ROOT/scripts/rewrite-corelib-refs.fsx" "$STAGE2_DIR"/*.dll \
      > "$BUILD_DIR/rewrite-corelib-refs-stage2.log" 2>&1 || \
      die "stage-2 CLI bundle: corelib-ref rewrite failed (see $BUILD_DIR/rewrite-corelib-refs-stage2.log)"
  else
    info "SKIP_COREREF_REWRITE=1; leaving stage-2 DLLs with raw CoreLib refs"
  fi

  # Sanity check: Lyric.Lyric.Cli.dll must land in stage2/.  If it
  # doesn't, something in the emitter cache layout changed and the
  # comparison will be meaningless.
  [[ -f "$STAGE2_DIR/Lyric.Lyric.Cli.dll" ]] || \
    die "stage-2 CLI bundle: Lyric.Lyric.Cli.dll not found in $STAGE2_DIR after copy"

  # -------------------------------------------------------------------------
  # Compare stage-1 and stage-2 outputs file-by-file (informational).
  # Intrinsic identity fields (MVID, PE timestamp, checksum) are precisely
  # normalized; a genuine nondeterminism such as the F# `build_date` wall-clock
  # is NOT masked and surfaces as a real DIFF.
  # -------------------------------------------------------------------------
  info "  comparing stage-1 vs stage-2 F# bundle outputs (identity fields normalized)"
  local diffs=0
  shopt -s nullglob
  for f in "$STAGE1_DIR"/*.dll; do
    local name
    name="$(basename "$f")"
    local f1="$STAGE1_DIR/$name"
    local f2="$STAGE2_DIR/$name"
    if [[ ! -f "$f2" ]]; then
      echo "  MISSING: $name (stage-2 missing)" >&2
      diffs=$((diffs + 1))
      continue
    fi
    if ! compare_stage1_stage2_dlls "$f1" "$f2"; then
      echo "  DIFF:    $name (stage-1 vs stage-2 differ after normalizing identity fields)" >&2
      diffs=$((diffs + 1))
    else
      echo "  MATCH:   $name"
    fi
  done
  # Reverse check: flag DLLs present in stage-2 but absent from stage-1.
  # Such extra assemblies indicate an unexpected build artefact or a package
  # name change between stages.
  for f in "$STAGE2_DIR"/*.dll; do
    local name
    name="$(basename "$f")"
    if [[ ! -f "$STAGE1_DIR/$name" ]]; then
      echo "  EXTRA:   $name (stage-2 only — not present in stage-1)" >&2
      diffs=$((diffs + 1))
    fi
  done
  shopt -u nullglob

  if [[ $diffs -eq 0 ]]; then
    ok "Stage-0 diagnostic: all F# bundle DLLs match (modulo intrinsic identity fields)"
  else
    # NEVER fatal: the F# stage-0 emitter is non-reproducible by design (it
    # embeds a `build_date` wall-clock in `Lyric.SdkVersion`) and is frozen on
    # a deletion schedule.  The STRICT gate is the self-hosted check in (a).
    info "  stage-0 diagnostic: $diffs F# bundle DLL(s) differ (expected — see Lyric.Stdlib.dll build_date)"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

stage0
[[ $MAX_STAGE -ge 1 ]] && stage1
[[ $MAX_STAGE -ge 2 ]] && stage2

info "Bootstrap finished (max stage: $MAX_STAGE)"
