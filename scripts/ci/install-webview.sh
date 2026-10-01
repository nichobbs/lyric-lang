#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# install-webview.sh — build and install the C `webview` library (docs/65
# §10.2, U5) that the lyric-ui desktop host binds with `@library("webview")`.
#
# Few distributions package libwebview, so this builds the pinned upstream
# release from source as a shared library on top of WebKitGTK 4.1 (Linux).
# It is the documented install path for users (book ch. 31) and what CI runs.
#
# Usage: bash scripts/ci/install-webview.sh [prefix]
#   prefix  install prefix (default /usr/local); the library lands in
#           <prefix>/lib/libwebview.so and the header in <prefix>/include.
#
# Requires: cmake, a C++ compiler, pkg-config and libwebkit2gtk-4.1-dev
# (apt-get install -y libwebkit2gtk-4.1-dev cmake g++ pkg-config).
# ---------------------------------------------------------------------------
set -euo pipefail

WEBVIEW_VERSION="0.12.0"
# The tag's commit, so a moved tag cannot change what is built.
WEBVIEW_COMMIT="3ab4b5d722438fc8a13e6ca830c5e2372d19a01d"
prefix="${1:-/usr/local}"

if ! pkg-config --exists webkit2gtk-4.1; then
  echo "::error::WebKitGTK 4.1 development files not found; install libwebkit2gtk-4.1-dev" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$WEBVIEW_VERSION" \
  https://github.com/webview/webview.git "$work/src"
actual="$(git -C "$work/src" rev-parse HEAD)"
if [ "$actual" != "$WEBVIEW_COMMIT" ]; then
  echo "::error::webview $WEBVIEW_VERSION resolved to $actual, expected $WEBVIEW_COMMIT" >&2
  exit 1
fi

cmake -S "$work/src" -B "$work/build" -G "Unix Makefiles" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DWEBVIEW_BUILD_SHARED_LIBRARY=ON \
  -DWEBVIEW_BUILD_STATIC_LIBRARY=OFF \
  -DWEBVIEW_BUILD_TESTS=OFF \
  -DWEBVIEW_BUILD_EXAMPLES=OFF \
  -DWEBVIEW_BUILD_DOCS=OFF \
  -DWEBVIEW_INSTALL_DOCS=OFF \
  -DWEBVIEW_ENABLE_CHECKS=OFF \
  -DWEBVIEW_ENABLE_PACKAGING=OFF \
  -DWEBVIEW_INSTALL_TARGETS=ON >/dev/null
cmake --build "$work/build" --parallel >/dev/null
if [ -w "$prefix" ] || [ "$(id -u)" = "0" ]; then
  cmake --install "$work/build" >/dev/null
else
  sudo cmake --install "$work/build" >/dev/null
fi
if command -v ldconfig >/dev/null; then
  if [ "$(id -u)" = "0" ]; then ldconfig; else sudo ldconfig; fi
fi
echo "webview $WEBVIEW_VERSION installed under $prefix"
