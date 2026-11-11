#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-tool.sh - provision CI tools without depending on a single Ubuntu
# archive mirror.
#
# GitHub-hosted runners resolve apt through azure.archive.ubuntu.com,
# archive.ubuntu.com and security.ubuntu.com.  When those hosts are
# unreachable every `apt-get update && apt-get install` step fails before any
# test runs.  This script keeps the same tool versions and the same checks,
# but takes each tool from the first source that works:
#
#   z3            the pinned upstream release zip (SHA-256 verified), the same
#                 version the runner's Ubuntu release packages; `apt` only if
#                 GitHub itself cannot be reached.
#   aot-prereqs   what the runner image already ships (clang, binutils, zlib
#                 headers); `apt` for anything missing; a pinned zlib source
#                 tarball as the last resort for the zlib development files.
#   apt PKG...    installs only the packages that are missing, from the
#                 runner's configured mirrors; if that fails, from an
#                 alternate Ubuntu archive mirror.  apt still verifies every
#                 index against the Ubuntu archive keyring, so the mirror is
#                 not trusted.
#
# Usage: scripts/ci/install-tool.sh z3 | aot-prereqs | apt PKG...
# ---------------------------------------------------------------------------
set -euo pipefail

Z3_VERSION="4.13.3"
Z3_SHA256_X64="32c7377026733c9d7b33c21cd77a68f50ba682367207b031a6bfd80140a8722f"
Z3_ZIP="z3-${Z3_VERSION}-x64-glibc-2.35.zip"
Z3_URL="https://github.com/Z3Prover/z3/releases/download/z3-${Z3_VERSION}/${Z3_ZIP}"

ZLIB_VERSION="1.3.1"
ZLIB_SHA256="9a93b2b7dfdac77ceba5a558a580e74667dd6fede4585b91eefb60f03b72df23"
ZLIB_URL="https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz"

# Alternate archive mirrors, tried in order after the runner's own mirrors.
ALT_MIRRORS=(
  "https://mirrors.edge.kernel.org/ubuntu"
  "https://mirror.us.leaseweb.net/ubuntu"
  "https://mirrors.xtom.com/ubuntu"
)

sudo_cmd=""
if [ "$(id -u)" != "0" ]; then sudo_cmd="sudo"; fi

log() { echo "install-tool: $*" >&2; }

fetch() {
  # fetch URL OUT: bounded retries; GitHub release downloads redirect.
  curl -fsSL --retry 4 --retry-delay 3 --retry-all-errors --connect-timeout 20 --max-time 600 -o "$2" "$1"
}

verify_sha256() {
  echo "$2  $1" | sha256sum -c - >/dev/null || {
    echo "::error::SHA-256 mismatch for $1 (expected $2, got $(sha256sum "$1" | cut -d' ' -f1))" >&2
    return 1
  }
}

# ---- apt with an alternate-mirror fallback ---------------------------------

apt_missing() {
  local p
  for p in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
      echo "$p"
    fi
  done
}

apt_flags=(-o DPkg::Lock::Timeout=900 -o Acquire::Retries=0 -o Acquire::http::Timeout=15 -o Acquire::https::Timeout=15)

apt_default() {
  $sudo_cmd rm -f /etc/apt/sources.list.d/google-chrome.list*
  $sudo_cmd apt-get "${apt_flags[@]}" update -qq && \
    $sudo_cmd apt-get "${apt_flags[@]}" install -y -qq --no-install-recommends "$@"
}

apt_alternate() {
  local codename mirror work
  codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  [ -n "$codename" ] || { log "cannot determine the Ubuntu codename"; return 1; }
  for mirror in "${ALT_MIRRORS[@]}"; do
    work="$(mktemp -d)"
    mkdir -p "$work/sources.d" "$work/lists/partial"
    cat > "$work/sources.d/alt.sources" <<EOF
Types: deb
URIs: ${mirror}
Suites: ${codename} ${codename}-updates ${codename}-security
Components: main universe multiverse restricted
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
    local alt=(-o "Dir::Etc::sourcelist=/dev/null" -o "Dir::Etc::sourceparts=$work/sources.d" -o "Dir::State::Lists=$work/lists")
    log "trying alternate mirror ${mirror}"
    if $sudo_cmd apt-get "${apt_flags[@]}" "${alt[@]}" update -qq && \
       $sudo_cmd apt-get "${apt_flags[@]}" "${alt[@]}" install -y -qq --no-install-recommends "$@"; then
      return 0
    fi
  done
  return 1
}

apt_install() {
  local missing
  missing="$(apt_missing "$@")"
  if [ -z "$missing" ]; then
    log "already installed: $*"
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $missing
  log "installing with apt: $*"
  apt_default "$@" && return 0
  log "the runner's apt mirrors failed; falling back to alternate mirrors"
  apt_alternate "$@" && return 0
  echo "::error::could not install $* from any apt mirror" >&2
  return 1
}

# ---- z3 --------------------------------------------------------------------

install_z3() {
  if command -v z3 >/dev/null 2>&1 && z3 --version 2>/dev/null | grep -q "Z3 version ${Z3_VERSION}"; then
    log "z3 ${Z3_VERSION} already installed"
    return 0
  fi
  if [ "$(uname -m)" != "x86_64" ]; then
    log "no pinned z3 release for $(uname -m); using apt"
    apt_install z3
    return
  fi
  local work
  work="$(mktemp -d)"
  if ! fetch "$Z3_URL" "$work/z3.zip"; then
    log "could not download ${Z3_URL}; using apt"
    apt_install z3
    return
  fi
  verify_sha256 "$work/z3.zip" "$Z3_SHA256_X64"
  unzip -q "$work/z3.zip" -d "$work/x"
  local dir
  dir="$(find "$work/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -x "$dir/bin/z3" ] || chmod +x "$dir/bin/z3"
  local dest="/opt/z3-${Z3_VERSION}"
  $sudo_cmd rm -rf "$dest"
  $sudo_cmd mkdir -p /opt
  $sudo_cmd cp -a "$dir" "$dest"
  $sudo_cmd ln -sf "$dest/bin/z3" /usr/local/bin/z3
  if ! z3 --version >/dev/null 2>&1; then
    # A dynamically linked z3 needs libz3 on the loader path.
    echo "$dest/bin" | $sudo_cmd tee /etc/ld.so.conf.d/z3.conf >/dev/null
    [ -d "$dest/lib" ] && echo "$dest/lib" | $sudo_cmd tee -a /etc/ld.so.conf.d/z3.conf >/dev/null
    $sudo_cmd ldconfig
  fi
  z3 --version
}

# ---- native AOT prerequisites (clang, binutils, zlib development files) ----

zlib_usable() {
  printf '#include <zlib.h>\nint main(void){return zlibVersion()==0;}\n' \
    | clang -x c - -lz -o /dev/null 2>/dev/null
}

install_zlib_from_source() {
  local work
  work="$(mktemp -d)"
  fetch "$ZLIB_URL" "$work/zlib.tar.gz"
  verify_sha256 "$work/zlib.tar.gz" "$ZLIB_SHA256"
  tar -xzf "$work/zlib.tar.gz" -C "$work"
  (
    cd "$work/zlib-${ZLIB_VERSION}"
    ./configure --prefix=/usr/local >/dev/null
    make -j"$(nproc)" >/dev/null
    $sudo_cmd make install >/dev/null
  )
  $sudo_cmd ldconfig
}

install_aot_prereqs() {
  if ! command -v clang >/dev/null 2>&1; then
    local v
    for v in 22 21 20 19 18; do
      if command -v "clang-$v" >/dev/null 2>&1; then
        $sudo_cmd update-alternatives --install /usr/bin/clang clang "$(command -v "clang-$v")" 100
        break
      fi
    done
  fi
  command -v clang >/dev/null 2>&1 || apt_install clang
  if ! command -v ld >/dev/null 2>&1 || ! command -v objdump >/dev/null 2>&1; then
    apt_install binutils
  fi
  if ! zlib_usable; then
    log "zlib development files not found"
    apt_install zlib1g-dev || true
    if ! zlib_usable; then
      log "building zlib ${ZLIB_VERSION} from the pinned source tarball"
      install_zlib_from_source
    fi
  fi
  zlib_usable || { echo "::error::clang cannot link against zlib" >&2; exit 1; }
  clang --version | head -n 1
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
  z3) install_z3 ;;
  aot-prereqs) install_aot_prereqs ;;
  apt) [ $# -gt 0 ] || { echo "install-tool: apt needs package names" >&2; exit 2; }; apt_install "$@" ;;
  *) echo "usage: install-tool.sh z3 | aot-prereqs | apt PKG..." >&2; exit 2 ;;
esac
