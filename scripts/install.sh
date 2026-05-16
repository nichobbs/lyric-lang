#!/usr/bin/env sh
# install.sh — zero-prerequisite Lyric compiler installer
#
# Detects the current platform, downloads the appropriate standalone binary
# archive from the latest GitHub Release, and installs it to ~/.lyric/bin.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/nichobbs/lyric-lang/main/scripts/install.sh | sh
#   curl -fsSL ... | sh -s -- --version 0.1.0
#   curl -fsSL ... | sh -s -- --dir /usr/local/bin
#
# Options:
#   --version VERSION   Install a specific version (default: latest)
#   --dir DIR           Installation directory (default: ~/.lyric/bin)
#   --no-path           Skip PATH modification
#
# Requirements: curl or wget, tar (Linux/macOS), unzip (Windows/Git Bash)

set -eu

GITHUB_REPO="nichobbs/lyric-lang"
INSTALL_DIR="${HOME}/.lyric/bin"
VERSION=""
MODIFY_PATH=1

# ── Argument parsing ─────────────────────────────────────────────────────────

while [ $# -gt 0 ]; do
  case "$1" in
    --version)
      case "$2" in
        [0-9]*.[0-9]*.[0-9]*) VERSION="$2" ;;
        *) err "--version must be a semver string (e.g. 1.0.0)" ;;
      esac
      shift 2 ;;
    --dir)       INSTALL_DIR="$2"; shift 2 ;;
    --no-path)   MODIFY_PATH=0;    shift ;;
    *)           echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

say() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

need_cmd() {
  if ! command -v "$1" > /dev/null 2>&1; then
    err "required command not found: $1 — please install it and retry"
  fi
}

download() {
  url="$1"; dest="$2"
  if command -v curl > /dev/null 2>&1; then
    curl --proto '=https' --tlsv1.2 -fsSL -o "$dest" "$url"
  elif command -v wget > /dev/null 2>&1; then
    wget -q -O "$dest" "$url"
  else
    err "neither curl nor wget found; install one and retry"
  fi
}

# ── Platform detection ────────────────────────────────────────────────────────

detect_platform() {
  OS="$(uname -s 2>/dev/null || true)"
  ARCH="$(uname -m 2>/dev/null || true)"

  case "$OS" in
    Linux)
      case "$ARCH" in
        x86_64)  RID="linux-x64";  ARCHIVE_EXT="tar.gz" ;;
        aarch64) RID="linux-arm64"; ARCHIVE_EXT="tar.gz" ;;
        *)       err "unsupported Linux architecture: $ARCH" ;;
      esac
      ;;
    Darwin)
      case "$ARCH" in
        arm64)  RID="osx-arm64"; ARCHIVE_EXT="tar.gz" ;;
        x86_64) RID="osx-x64";   ARCHIVE_EXT="tar.gz" ;;
        *)      err "unsupported macOS architecture: $ARCH" ;;
      esac
      ;;
    MINGW*|MSYS*|CYGWIN*)
      RID="win-x64"; ARCHIVE_EXT="zip" ;;
    *)
      err "unsupported operating system: $OS"
      ;;
  esac
}

# ── Version resolution ────────────────────────────────────────────────────────

resolve_version() {
  if [ -z "$VERSION" ]; then
    say "Resolving latest Lyric release..."
    RELEASES_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    RELEASE_JSON="$(mktemp)"
    download "$RELEASES_URL" "$RELEASE_JSON"
    # Extract tag_name from JSON without requiring jq.
    VERSION="$(sed -n 's/.*"tag_name": *"v\([^"]*\)".*/\1/p' "$RELEASE_JSON" | head -1)"
    rm -f "$RELEASE_JSON"
    if [ -z "$VERSION" ]; then
      err "could not determine latest version from GitHub API"
    fi
  fi
  say "Installing Lyric ${VERSION} (${RID})"
}

# ── Download and install ──────────────────────────────────────────────────────

install_lyric() {
  ARCHIVE_NAME="lyric-${VERSION}-${RID}.${ARCHIVE_EXT}"
  DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/v${VERSION}/${ARCHIVE_NAME}"
  TMPDIR_INST="$(mktemp -d)"

  say "Downloading ${ARCHIVE_NAME}..."
  download "$DOWNLOAD_URL" "${TMPDIR_INST}/${ARCHIVE_NAME}"

  say "Extracting..."
  mkdir -p "$INSTALL_DIR"

  case "$ARCHIVE_EXT" in
    tar.gz)
      need_cmd tar
      tar -xzf "${TMPDIR_INST}/${ARCHIVE_NAME}" -C "$INSTALL_DIR"
      ;;
    zip)
      need_cmd unzip
      unzip -qo "${TMPDIR_INST}/${ARCHIVE_NAME}" -d "$INSTALL_DIR"
      ;;
  esac

  rm -rf "$TMPDIR_INST"

  # Ensure the binary is executable.
  LYRIC_BIN="${INSTALL_DIR}/lyric"
  if [ -f "${INSTALL_DIR}/lyric.exe" ]; then
    LYRIC_BIN="${INSTALL_DIR}/lyric.exe"
  fi
  chmod +x "$LYRIC_BIN" 2>/dev/null || true

  say "Installed: $LYRIC_BIN"
}

# ── PATH setup ────────────────────────────────────────────────────────────────

update_path() {
  [ "$MODIFY_PATH" -eq 0 ] && return
  SHELL_PROFILE=""
  case "${SHELL:-}" in
    */bash)  SHELL_PROFILE="${HOME}/.bashrc" ;;
    */zsh)   SHELL_PROFILE="${HOME}/.zshrc"  ;;
    */fish)  SHELL_PROFILE="${HOME}/.config/fish/config.fish" ;;
  esac

  # Check whether INSTALL_DIR is already in PATH.
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) return ;;
  esac

  if [ -n "$SHELL_PROFILE" ]; then
    LINE=""
    if [ "${SHELL_PROFILE##*.}" = "fish" ]; then
      LINE="fish_add_path \"${INSTALL_DIR}\""
    else
      LINE="export PATH=\"${INSTALL_DIR}:\${PATH}\""
    fi
    printf '\n# Lyric compiler\n%s\n' "$LINE" >> "$SHELL_PROFILE"
    say "Added ${INSTALL_DIR} to PATH in ${SHELL_PROFILE}"
    say "(Restart your shell or run: source ${SHELL_PROFILE})"
  else
    say ""
    say "Add the following line to your shell profile to make 'lyric' available:"
    say "  export PATH=\"${INSTALL_DIR}:\${PATH}\""
  fi
}

# ── Verify installation ───────────────────────────────────────────────────────

verify() {
  LYRIC_BIN="${INSTALL_DIR}/lyric"
  if [ -f "${INSTALL_DIR}/lyric.exe" ]; then
    LYRIC_BIN="${INSTALL_DIR}/lyric.exe"
  fi
  if "$LYRIC_BIN" --version > /dev/null 2>&1; then
    say ""
    say "Lyric ${VERSION} installed successfully."
    say "Run 'lyric --help' to get started."
  else
    say ""
    say "Lyric ${VERSION} installed to ${LYRIC_BIN}."
    say "(Note: run verification skipped — the binary may require a shell restart.)"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

detect_platform
resolve_version
install_lyric
update_path
verify
