#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-sdl3.sh: build SDL3 from the pinned libsdl.org release tarball into a
# prefix, for lyric-window's CI (docs/67 G4).  A headless build: every window-system
# and sound-server backend is switched off explicitly (a runner image may carry some
# of their development packages) and the console-build flag acknowledges that, so the
# offscreen/dummy video drivers and the dummy/disk audio drivers are what it provides.
# A developer machine uses its distribution's SDL3.
#
# With --x11 the X11 video driver is built too (for the window-system tests under Xvfb); the
# caller installs the X11 development packages first (libx11-dev libxext-dev libxcursor-dev
# libxi-dev libxrandr-dev libxfixes-dev libxrender-dev libxtst-dev).  The headless drivers
# stay available either way.
#
# Usage: bash scripts/ci/build-sdl3.sh [--x11] <prefix>
# Afterwards: PKG_CONFIG_PATH=<prefix>/lib/pkgconfig LD_LIBRARY_PATH=<prefix>/lib
# ---------------------------------------------------------------------------
set -euo pipefail

SDL_VERSION="3.4.18"
SDL_SHA256="9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3"
SDL_URL="https://libsdl.org/release/SDL3-${SDL_VERSION}.tar.gz"

x11=0
if [ "${1:-}" = "--x11" ]; then
  x11=1
  shift
fi
prefix="${1:?usage: build-sdl3.sh [--x11] <prefix>}"
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"
marker="$prefix/.sdl3-$SDL_VERSION-x11-$x11"
if [ -f "$marker" ]; then
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
windowing=(-DSDL_UNIX_CONSOLE_BUILD=ON -DSDL_X11=OFF)
if [ "$x11" = 1 ]; then
  windowing=(-DSDL_X11=ON -DSDL_X11_XSCRNSAVER=OFF)
fi
cmake "${generator[@]}" -S "$work/src" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
  "${windowing[@]}" -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_TESTS=OFF \
  -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF -DSDL_VIVANTE=OFF -DSDL_OPENGL=OFF -DSDL_OPENGLES=OFF \
  -DSDL_VULKAN=OFF -DSDL_ALSA=OFF -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF -DSDL_JACK=OFF -DSDL_SNDIO=OFF \
  -DSDL_IBUS=OFF -DSDL_DBUS=OFF -DSDL_LIBUDEV=OFF -DSDL_LIBURING=OFF
cmake --build "$work/build" -j"$(nproc)"
cmake --install "$work/build"
touch "$marker"
