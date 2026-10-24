#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# windows-graphics-e2e.sh: the docs/67 G4-G7 examples on Windows x86-64
# (x86_64-pc-windows-msvc, G9), run on a Windows host from Git Bash.
#
#   1. Builds FreeType and HarfBuzz (scripts/ci/build-text-libs-windows.sh) and
#      fetches the fonts the Linux job uses, at the same pinned releases.
#   2. Checks what is target-specific against the Windows headers: the struct
#      offsets the safe layers read (the `*_layout_check.c` files) and every
#      generated kernel, regenerated with `lyric bindgen --triple
#      x86_64-pc-windows-msvc --check`.
#   3. Restores, builds and runs the examples.  SDL3 and wgpu-native come from
#      their pinned Windows archives (`lyric restore`), which bundles their
#      DLLs beside each executable; FreeType and HarfBuzz come through
#      pkg-config.  wgpu renders through Direct3D 12 on WARP, Windows' software
#      rasteriser, and the offscreen frames are compared with the goldens the
#      Linux job checks.  The windowed examples open a real Win32 window,
#      exercising the HWND surface.
#
# Needs clang, lld-link, CMake and Ninja (an LLVM and Visual Studio Build Tools
# install), pkg-config, curl and Python on PATH.
#
# Usage: LYRIC_BIN=path/to/lyric.exe bash scripts/ci/windows-graphics-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
lyric_bin="${LYRIC_BIN:?set LYRIC_BIN to the lyric executable}"
triple="x86_64-pc-windows-msvc"
py="$(command -v python3 || command -v python)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "=== FreeType, HarfBuzz and fonts ==="
prefix="${TEXT_LIBS_PREFIX:-$work/text-libs}"
bash scripts/ci/build-text-libs-windows.sh "$prefix"
PKG_CONFIG_PATH="$(cygpath -m "$prefix/lib/pkgconfig")"
export PKG_CONFIG_PATH
pkg-config --modversion freetype2 harfbuzz

fetch() {
  local url="$1" sha="$2" out="$3"
  curl -fsSL --retry 3 -o "$out" "$url"
  echo "$sha  $out" | sha256sum -c -
}
fonts="$work/fonts"
mkdir -p "$fonts"
fetch https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.zip \
  7576310b219e04159d35ff61dd4a4ec4cdba4f35c00e002a136f00e96a908b0a "$fonts/dejavu.zip"
fetch "https://downloads.sourceforge.net/project/wqy/wqy-zenhei/0.9.45%20%28Fighting-state%20RC1%29/wqy-zenhei-0.9.45.tar.gz" \
  e4b7e306475bf9427d1757578f0e4528930c84c44eaa3f167d4c42f110ee75d6 "$fonts/wqy.tar.gz"
(cd "$fonts" && cmake -E tar xf dejavu.zip && cmake -E tar xf wqy.tar.gz)
LYRIC_TEXT_FONT_LATIN="$(cygpath -m "$fonts/dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf")"
LYRIC_TEXT_FONT_CJK="$(cygpath -m "$fonts/wqy-zenhei/wqy-zenhei.ttc")"
export LYRIC_TEXT_FONT_LATIN LYRIC_TEXT_FONT_CJK

# SDL3's headers, from the archive lyric-window's manifest pins (its restore
# extracts only the library).
fetch https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-devel-3.4.18-VC.zip \
  78d84602ae616cfe26b33a73b7d3b9b6b56e8a6650e53d92c9c6ca938f747acd "$work/sdl3.zip"
(cd "$work" && cmake -E tar xf sdl3.zip)
sdl_include="$(cygpath -m "$work/SDL3-3.4.18/include")"

echo "=== layouts and bindings against the Windows headers ==="
text_cflags="$(pkg-config --cflags freetype2 harfbuzz)"
# shellcheck disable=SC2086
clang -fsyntax-only $text_cflags lyric-text/native/text_layout_check.c
clang -fsyntax-only -I lyric-gpu/native lyric-gpu/native/wgpu_layout_check.c
clang -fsyntax-only -I "$sdl_include" lyric-window/native/sdl_layout_check.c
text_includes="$(pkg-config --cflags-only-I freetype2 harfbuzz | sed 's/-I/-I /g')"
(cd lyric-gpu && "$lyric_bin" bindgen native/include/wgpu_bindings.h --package Gpu.Kernel.Wgpu \
  --allow native/wgpu.allow --library wgpu_native-release -o src/_kernel/wgpu.l --triple "$triple" --check)
(cd lyric-window && "$lyric_bin" bindgen native/sdl_bindings.h --package Window.Kernel.Sdl \
  --allow native/sdl.allow --library SDL3 -o src/_kernel/sdl.l -I "$sdl_include" --triple "$triple" --check)
# shellcheck disable=SC2086
(cd lyric-text && "$lyric_bin" bindgen native/freetype_bindings.h --package Text.Kernel.Freetype \
  --allow native/freetype.allow --library freetype -o src/_kernel/freetype_windows.l \
  --cfg 'target_os = "windows"' --triple "$triple" --check $text_includes)
# shellcheck disable=SC2086
(cd lyric-text && "$lyric_bin" bindgen native/harfbuzz_bindings.h --package Text.Kernel.Harfbuzz \
  --allow native/harfbuzz.allow --library harfbuzz -o src/_kernel/harfbuzz_windows.l \
  --cfg 'target_os = "windows"' --triple "$triple" --check $text_includes)

build() {
  local manifest="$1" out="$2"
  "$lyric_bin" restore --manifest "$manifest"
  "$lyric_bin" build --target native --manifest "$manifest" -o "$out"
}

echo "=== lyric-window demo (G4) ==="
build lyric-window/examples/demo/lyric.toml "$work/demo"
out="$(SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=disk SDL_AUDIO_DISK_OUTPUT_FILE="$(cygpath -m "$work/audio.raw")" \
  "$work/demo" 2>/dev/null | tr -d '\r')"
echo "$out"
for expected in \
  "window: 320x200" \
  "event: key-down 97 scancode 4 mods 1 repeat false" \
  "event: quit" \
  "window now: 400x300" \
  "native window: unavailable" \
  "clipboard: héllo clipboard" \
  "time advanced: true" \
  "audio queued after playback: 0" \
  "done"; do
  echo "$out" | grep -qxF "$expected" || { echo "::error::demo output lacks: $expected"; exit 1; }
done
"$py" -I - "$work/audio.raw" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
samples = struct.unpack("<%df" % (len(data) // 4), data)
loud = [s for s in samples if abs(abs(s) - 0.25) < 1e-6]
if len(loud) < 24000:
    sys.exit("expected 24000 samples of the tone in the disk audio output, found %d" % len(loud))
print("audio output: %d samples, %d of them the tone" % (len(samples), len(loud)))
PY

echo "=== lyric-gpu compute, triangle and quad (G5, WARP) ==="
for example in compute triangle quad; do
  build "lyric-gpu/examples/$example/lyric.toml" "$work/$example"
done
for f in "$work"/*.dll; do
  echo "bundled: $(basename "$f")"
done
out="$("$work/compute" | tr -d '\r')"
echo "$out"
echo "$out" | grep -q "checked 1000 values, wrong=0"
echo "$out" | grep -q "invalid shader rejected: with a message"
"$work/triangle" lyric-gpu/examples/triangle/golden/triangle-64.rgba
"$work/quad" lyric-gpu/examples/quad/golden/quad-64.rgba

echo "=== lyric-gpu window: a Win32 window and its HWND surface ==="
build lyric-gpu/examples/window/lyric.toml "$work/window"
"$work/window" 6 2>&1 | tr -d '\r' | tee "$work/window.out"
grep -q '^presented' "$work/window.out" || { echo "::error::the window example never presented a frame"; exit 1; }

echo "=== lyric-text shape (G6) ==="
build lyric-text/examples/shape/lyric.toml "$work/shape"
out="$(LYRIC_TEXT_GOLDEN=lyric-text/examples/shape/golden/scene-384x160.pgm "$work/shape" | tr -d '\r')"
echo "$out"
echo "$out" | grep -q "fallback + wrap ok"
echo "$out" | grep -q "^golden: "

echo "=== lyric-draw scene (G6) ==="
build lyric-draw/examples/scene/lyric.toml "$work/scene"
"$work/scene" lyric-draw/examples/scene/golden/scene-256x192.rgba
# WARP, the runner's D3D12 software rasteriser, draws this frame several times slower than
# lavapipe (about 140 ms against 22 ms), so the lavapipe ceiling does not apply here.
LYRIC_DRAW_STRESS_BUDGET_MS=500 "$work/scene" --stress

echo "=== lyric-game Breakout (G7) ==="
example=lyric-game/examples/breakout
build "$example/app/lyric.toml" "$work/breakout"
"$work/breakout" --check "$example/replays/bot-seed5.replay" 784632209 "$example/replays/golden-final-320x240.rgba"
SDL_AUDIODRIVER=dummy "$work/breakout" --play "$example/replays/bot-seed5.replay" --record "$work/again.replay" \
  2>&1 | tr -d '\r' | tee "$work/play.out"
grep -q '^presented' "$work/play.out" || { echo "::error::the game never presented a frame"; exit 1; }
grep -q '^recorded 900 steps' "$work/play.out" || { echo "::error::the loop did not play and record all 900 steps"; exit 1; }
cmp "$example/replays/bot-seed5.replay" "$work/again.replay" || { echo "::error::the recorded input differs from the recording played"; exit 1; }

echo "Windows graphics examples passed"
