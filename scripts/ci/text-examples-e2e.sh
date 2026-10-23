#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# text-examples-e2e.sh: lyric-text's example on the native backend, over
# FreeType and HarfBuzz (docs/67 G6).
#   - the example shapes Latin, Arabic and CJK text, checks kerning, joining and
#     visual order, rasterises and atlas-packs glyphs, falls back from a Latin to a
#     CJK font, wraps lines and right-aligns an Arabic paragraph, and lays out runs of
#     one direction (layoutRun) with their brackets swapped and their words ordered;
#   - it renders a mixed Latin/Arabic/CJK scene and compares it with the checked-in
#     golden image within a differing-pixel tolerance (another FreeType version
#     rasterises edges a little differently).
# FreeType and HarfBuzz are found with pkg-config; the fonts are DejaVu Sans and
# WenQuanYi Zen Hei, from fonts-dejavu-core and fonts-wqy-zenhei.
#
# Usage: LYRIC_BIN=<path to lyric> bash scripts/ci/text-examples-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"

latin=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
cjk=/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc
if ! pkg-config --exists freetype2 harfbuzz || [ ! -f "$latin" ] || [ ! -f "$cjk" ]; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq libfreetype-dev libharfbuzz-dev fonts-dejavu-core fonts-wqy-zenhei
fi
[ -f "$latin" ] && [ -f "$cjk" ] || { echo "::error::the DejaVu Sans and WenQuanYi Zen Hei fonts are not installed"; exit 1; }

# The struct offsets text.l reads match the installed headers.
cc -fsyntax-only $(pkg-config --cflags freetype2 harfbuzz) lyric-text/native/text_layout_check.c

# The kernel bindings are generated; they must match the headers and allow-lists.
includes=$(pkg-config --cflags-only-I freetype2 harfbuzz | sed 's/-I/-I /g')
(cd lyric-text && "$LYRIC_BIN" bindgen native/freetype_bindings.h --package Text.Kernel.Freetype \
  --allow native/freetype.allow --library freetype -o src/_kernel/freetype.l --check $includes)
(cd lyric-text && "$LYRIC_BIN" bindgen native/harfbuzz_bindings.h --package Text.Kernel.Harfbuzz \
  --allow native/harfbuzz.allow --library harfbuzz -o src/_kernel/harfbuzz.l --check $includes)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

manifest=lyric-text/examples/shape/lyric.toml
"$LYRIC_BIN" restore --manifest "$manifest"
"$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/shape"

echo "=== lyric-text shape ==="
out="$(LYRIC_TEXT_FONT_LATIN="$latin" LYRIC_TEXT_FONT_CJK="$cjk" \
  LYRIC_TEXT_GOLDEN=lyric-text/examples/shape/golden/scene-384x160.pgm "$work/shape")"
echo "$out"
echo "$out" | grep -q "fallback + wrap ok, runs ok"
echo "$out" | grep -q "^golden: "
