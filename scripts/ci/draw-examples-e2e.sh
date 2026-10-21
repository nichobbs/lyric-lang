#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# draw-examples-e2e.sh: lyric-draw's scene example on the native backend, drawn by
# wgpu-native on a software Vulkan device (docs/67 G6).
#   - the scene is a card with a shadow, a border, rounded shapes, an alpha-blended
#     image, and wrapped and clipped Latin, Arabic and CJK text from lyric-text;
#     its pixels are compared with the checked-in golden image, within a per-channel
#     tolerance and a differing-pixel budget (a software and a hardware rasteriser, and
#     different FreeType versions, place edge pixels differently).
# The wgpu-native library comes from lyric-gpu's pinned prebuilt archives via
# `lyric restore`; lavapipe (mesa-vulkan-drivers) is the Vulkan device; FreeType and
# HarfBuzz come from pkg-config and the fonts from fonts-dejavu-core and
# fonts-wqy-zenhei.
#
# Usage: LYRIC_BIN=<path to lyric> bash scripts/ci/draw-examples-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"

icd=""
for candidate in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
  if [ -f "$candidate" ]; then icd="$candidate"; break; fi
done
latin=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
cjk=/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc
if [ -z "$icd" ] || ! pkg-config --exists freetype2 harfbuzz || [ ! -f "$latin" ] || [ ! -f "$cjk" ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq mesa-vulkan-drivers libfreetype-dev libharfbuzz-dev fonts-dejavu-core fonts-wqy-zenhei
  for candidate in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
    if [ -f "$candidate" ]; then icd="$candidate"; break; fi
  done
fi
[ -n "$icd" ] || { echo "::error::no lavapipe Vulkan ICD (mesa-vulkan-drivers) on the runner"; exit 1; }
export VK_ICD_FILENAMES="$icd"
export LYRIC_TEXT_FONT_LATIN="$latin" LYRIC_TEXT_FONT_CJK="$cjk"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

manifest=lyric-draw/examples/scene/lyric.toml
"$LYRIC_BIN" restore --manifest "$manifest"
"$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/scene"

echo "=== lyric-draw scene ==="
"$work/scene" lyric-draw/examples/scene/golden/scene-256x192.rgba

# A text-heavy 1280x720 frame (about five thousand glyphs, laid out, packed and drawn) must stay
# within its frame budget on lavapipe; the budget in the example is a CPU-rendered ceiling, not
# the 16.6 ms a GPU frame would have.
echo "=== lyric-draw stress ==="
"$work/scene" --stress
