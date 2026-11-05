#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-accesskit.sh: AccessKit's C API (accesskit-c 0.23.2) for lyric-access's CI (docs/67 G10).
#
# Always: fetches the release archive that lyric-access/platform/lyric.toml pins (same URL and
# SHA-256) and installs its header as <prefix>/include/accesskit.h, for the layout check
# (lyric-access/platform/native/accesskit_layout_check.c) and `lyric bindgen --check`.
#
# With --source: also builds the library from the release's tagged source (verified by commit)
# with cargo, for a target the archive carries no library for (Linux arm64), and installs
# <prefix>/lib/libaccesskit.so with <prefix>/lib/pkgconfig/accesskit.pc, which the manifest's
# `pkg_config = "accesskit"` finds.  Needs Rust 1.87 or later (cargo on PATH).
#
# Usage: bash scripts/ci/build-accesskit.sh [--source] <prefix>
# Afterwards (--source): PKG_CONFIG_PATH=<prefix>/lib/pkgconfig LD_LIBRARY_PATH=<prefix>/lib
# ---------------------------------------------------------------------------
set -euo pipefail

VERSION="0.23.2"
ARCHIVE_URL="https://github.com/AccessKit/accesskit-c/releases/download/${VERSION}/accesskit-c-${VERSION}.zip"
ARCHIVE_SHA256="c7fa84f8f34fca909f662375737a54f98b17cf9eae51fffd94ab3d9f662e3681"
SOURCE_URL="https://github.com/AccessKit/accesskit-c"
SOURCE_COMMIT="99023c87eca49531a8e1efc4657e35779257a463"

source_build=0
if [ "${1:-}" = "--source" ]; then
  source_build=1
  shift
fi
prefix="${1:?usage: build-accesskit.sh [--source] <prefix>}"
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"
marker="$prefix/.accesskit-$VERSION-source-$source_build"
if [ -f "$marker" ]; then
  echo "accesskit-c $VERSION already in $prefix"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 -o "$work/accesskit.zip" "$ARCHIVE_URL"
if command -v sha256sum >/dev/null; then
  echo "$ARCHIVE_SHA256  $work/accesskit.zip" | sha256sum -c -
else
  echo "$ARCHIVE_SHA256  $work/accesskit.zip" | shasum -a 256 -c -
fi
mkdir -p "$prefix/include" "$work/archive"
(cd "$work/archive" && cmake -E tar xf ../accesskit.zip "accesskit-c-$VERSION/include/accesskit.h")
cp "$work/archive/accesskit-c-$VERSION/include/accesskit.h" "$prefix/include/accesskit.h"

if [ "$source_build" = 1 ]; then
  command -v cargo >/dev/null || { echo "::error::cargo is not on PATH (accesskit-c needs Rust 1.87 or later)"; exit 1; }
  git clone --quiet --depth 1 --branch "$VERSION" "$SOURCE_URL" "$work/src"
  actual="$(git -C "$work/src" rev-parse HEAD)"
  if [ "$actual" != "$SOURCE_COMMIT" ]; then
    echo "::error::accesskit-c tag $VERSION is $actual, not the pinned $SOURCE_COMMIT"
    exit 1
  fi
  (cd "$work/src" && cargo build --release --locked)
  mkdir -p "$prefix/lib/pkgconfig"
  cp "$work/src/target/release/libaccesskit.so" "$prefix/lib/libaccesskit.so"
  cat > "$prefix/lib/pkgconfig/accesskit.pc" <<PC
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: accesskit
Description: AccessKit C bindings (accesskit-c)
Version: $VERSION
Libs: -L\${libdir} -laccesskit
Cflags: -I\${includedir}
PC
fi
touch "$marker"
