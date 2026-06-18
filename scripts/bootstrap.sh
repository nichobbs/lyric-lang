#!/bin/bash
# bootstrap.sh — self-hosted Lyric compiler bootstrap
#
# Stage 0:  Download the latest released Lyric compiler binary (self-hosted).
#           No F# code is used — the compiler is fully self-hosted.
# Stage 1:  Use stage-0 lyric to compile the standard library (lyric-stdlib/)
#           via `lyric build --manifest` to produce Lyric.Stdlib.dll.
#           This DLL is then used by the AOT entry-point project to build
#           the final self-hosted CLI binary.
#
# Usage:
#   ./scripts/bootstrap.sh              # download stage-0 and compile stage-1
#   ./scripts/bootstrap.sh --stage 0   # download stage-0 binary only
#   ./scripts/bootstrap.sh --stage 1   # stages 0 + 1

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$REPO_ROOT/.bootstrap"
STAGE0_BIN="$BUILD_DIR/stage0/lyric"
STAGE1_DIR="$BUILD_DIR/stage1"
STDLIB_DIR="$REPO_ROOT/lyric-stdlib"

MAX_STAGE=1

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
# Stage 0 — Download released self-hosted Lyric compiler
# ---------------------------------------------------------------------------
stage0() {
  info "Stage 0: downloading released Lyric compiler (self-hosted)"
  mkdir -p "$BUILD_DIR/stage0-download"
  mkdir -p "$(dirname "$STAGE0_BIN")"

  # Determine the binary name based on OS and architecture
  local UNAME_S=$(uname -s)
  local ARCH=$(uname -m)
  local BINARY_NAME
  local RELEASE_VERSION="v0.1.8"

  case "$UNAME_S" in
    Linux)
      case "$ARCH" in
        x86_64)
          BINARY_NAME="lyric-0.1.8-linux-x64.tar.gz"
          ;;
        aarch64)
          BINARY_NAME="lyric-0.1.8-linux-arm64.tar.gz"
          ;;
        *)
          die "Unsupported Linux architecture: $ARCH"
          ;;
      esac
      ;;
    Darwin)
      case "$ARCH" in
        x86_64)
          BINARY_NAME="lyric-0.1.8-osx-x64.tar.gz"
          ;;
        arm64)
          BINARY_NAME="lyric-0.1.8-osx-arm64.tar.gz"
          ;;
        *)
          die "Unsupported macOS architecture: $ARCH"
          ;;
      esac
      ;;
    *)
      die "Unsupported operating system: $UNAME_S"
      ;;
  esac

  local RELEASE_URL="https://github.com/nichobbs/lyric-lang/releases/download/$RELEASE_VERSION/$BINARY_NAME"
  local DOWNLOAD_PATH="$BUILD_DIR/stage0-download/$BINARY_NAME"

  # Download if not already cached
  if [[ ! -f "$DOWNLOAD_PATH" ]]; then
    info "  downloading $RELEASE_VERSION from GitHub"
    curl -L -f "$RELEASE_URL" -o "$DOWNLOAD_PATH" || \
      die "failed to download stage-0 binary"
  fi

  # Extract to the stage0 directory
  mkdir -p "$BUILD_DIR/stage0-tmp"
  tar xzf "$DOWNLOAD_PATH" -C "$BUILD_DIR/stage0-tmp"

  # Move to final location
  if [[ -f "$BUILD_DIR/stage0-tmp/lyric" ]]; then
    chmod +x "$BUILD_DIR/stage0-tmp/lyric"
    mv "$BUILD_DIR/stage0-tmp/lyric" "$STAGE0_BIN"
    rm -rf "$BUILD_DIR/stage0-tmp"
  else
    die "extracted archive did not contain lyric binary"
  fi

  ok "Stage 0 complete — $STAGE0_BIN"
}

# ---------------------------------------------------------------------------
# Stage 1 — Compile the standard library using stage-0 lyric
# ---------------------------------------------------------------------------
stage1() {
  info "Stage 1: compiling standard library and Lyric compiler with stage-0"
  mkdir -p "$STAGE1_DIR"

  # Build the stdlib bundle via standard `lyric build --manifest` command
  info "  compiling stdlib bundle"
  cd "$STDLIB_DIR"
  LYRIC_STD_PATH="" "$STAGE0_BIN" build --manifest lyric.toml \
    -o "$STAGE1_DIR/Lyric.Stdlib.dll" --target dotnet 2>&1 || \
    die "stdlib bundle build failed"
  cd "$REPO_ROOT"

  # Build the self-hosted Lyric compiler packages
  info "  compiling Lyric compiler packages"
  cd "$REPO_ROOT/lyric-compiler/lyric"
  LYRIC_STD_PATH="$REPO_ROOT/lyric-stdlib" "$STAGE0_BIN" build --manifest lyric.toml \
    -o "$STAGE1_DIR/Lyric.Cli.dll" --target dotnet 2>&1 || \
    die "Lyric compiler build failed"
  cd "$REPO_ROOT"

  ok "Stage 1 complete — output in $STAGE1_DIR"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"

stage0
[[ $MAX_STAGE -ge 1 ]] && stage1

info "Bootstrap finished (max stage: $MAX_STAGE)"
