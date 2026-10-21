#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-sdl3.sh: build SDL3 from the pinned libsdl.org release tarball into a
# prefix, for lyric-window's CI (docs/67 G4).  A headless build: no X11,
# Wayland or sound-server dependencies, so the offscreen/dummy video drivers
# and the dummy/disk audio drivers are what it provides.  A developer machine
# uses its distribution's SDL3 (or this script without the console-build flag).
#
# Usage: bash scripts/ci/build-sdl3.sh <prefix>
# Afterwards: PKG_CONFIG_PATH=<prefix>/lib/pkgconfig LD_LIBRARY_PATH=<prefix>/lib
# ---------------------------------------------------------------------------
set -euo pipefail

SDL_VERSION="3.4.18"
SDL_SHA256="9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3"
SDL_URL="https://libsdl.org/release/SDL3-${SDL_VERSION}.tar.gz"

prefix="${1:?usage: build-sdl3.sh <prefix>}"
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"
if [ -f "$prefix/.sdl3-$SDL_VERSION" ]; then
  echo "SDL3 $SDL_VERSION already built in $prefix"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/sdl3.tar.gz" "$SDL_URL"
echo "$SDL_SHA256  $work/sdl3.tar.gz" | sha256sum -c -
mkdir "$work/src"
tar -xzf "$work/sdl3.tar.gz" -C "$work/src" --strip-components=1

generator=()
command -v ninja >/dev/null && generator=(-G Ninja)
cmake "${generator[@]}" -S "$work/src" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DSDL_UNIX_CONSOLE_BUILD=ON -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build"
touch "$prefix/.sdl3-$SDL_VERSION"
