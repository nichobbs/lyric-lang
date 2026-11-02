#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# macos-graphics-e2e.sh: the lyric-gpu, lyric-window, lyric-game and lyric-ui
# native examples on macOS over Metal (docs/67 G5 and G7, D317, #8563).
#
#   probe  builds the lyric-gpu compute example and runs it.  It exits 0 either
#          way and prints `metal=true` or `metal=false` (also appended to
#          $GITHUB_OUTPUT), because a hosted macOS VM may expose no Metal adapter.
#   run    runs the golden-image, window and Breakout checks; it needs one.
#
# Fonts: the goldens were drawn with DejaVu Sans, so the script needs it
# (`brew install --cask font-dejavu`, found under ~/Library/Fonts) and fails
# without it.  The lyric-text shape and lyric-draw scene examples also need
# WenQuanYi Zen Hei (CJK), which Homebrew does not ship, so they stay on Linux.
#
# Usage: LYRIC_BIN=<lyric> bash scripts/ci/macos-graphics-e2e.sh probe|run
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"
mode="${1:?usage: macos-graphics-e2e.sh probe|run}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Builds a manifest's example and echoes the executable inside its .app bundle.
build() {
  local manifest="$1" name="$2"
  "$LYRIC_BIN" restore --manifest "$manifest" >&2
  "$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/$name" >&2
  [ -x "$work/$name.app/Contents/MacOS/$name" ] || { echo "::error::$name.app was not written" >&2; exit 1; }
  echo "$work/$name.app/Contents/MacOS/$name"
}

if [ "$mode" = probe ]; then
  echo "=== Metal adapter probe ==="
  sw_vers
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset Model|Metal" || true
  exe="$(build lyric-gpu/examples/compute/lyric.toml compute)"
  if out="$("$exe" 2>&1)" && echo "$out" | grep -q "checked 1000 values, wrong=0"; then
    echo "$out"
    echo "metal=true"
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "metal=true" >> "$GITHUB_OUTPUT"
  else
    echo "$out"
    echo "no usable Metal adapter on this host: the GPU compute example did not run"
    echo "metal=false"
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "metal=false" >> "$GITHUB_OUTPUT"
  fi
  exit 0
fi

latin="${LYRIC_TEXT_FONT_LATIN:-$HOME/Library/Fonts/DejaVuSans.ttf}"
bold="${LYRIC_UI_FONT_BOLD:-$HOME/Library/Fonts/DejaVuSans-Bold.ttf}"
[ -f "$latin" ] || { echo "::error::DejaVu Sans is not installed ($latin)"; exit 1; }
[ -f "$bold" ] || { echo "::error::DejaVu Sans Bold is not installed ($bold)"; exit 1; }
export LYRIC_TEXT_FONT_LATIN="$latin" LYRIC_UI_FONT="$latin" LYRIC_UI_FONT_BOLD="$bold"

echo "=== lyric-gpu triangle and quad on Metal ==="
"$(build lyric-gpu/examples/triangle/lyric.toml triangle)" lyric-gpu/examples/triangle/golden/triangle-64.rgba
"$(build lyric-gpu/examples/quad/lyric.toml quad)" lyric-gpu/examples/quad/golden/quad-64.rgba

echo "=== lyric-gpu window: a Cocoa window presents frames ==="
window="$(build lyric-gpu/examples/window/lyric.toml window)"
"$window" 3 | tee "$work/window.out"
grep -q '^presented' "$work/window.out" || { echo "::error::the window example never presented a frame"; exit 1; }

echo "=== Breakout: headless replay on Metal ==="
example=lyric-game/examples/breakout
breakout="$(build "$example/app/lyric.toml" breakout)"
"$breakout" --check "$example/replays/bot-seed5.replay" 784632209 "$example/replays/golden-final-320x240.rgba"

echo "=== Breakout in a Cocoa window ==="
"$breakout" --play "$example/replays/bot-seed5.replay" --record "$work/again.replay" | tee "$work/play.out"
grep -q '^presented' "$work/play.out" || { echo "::error::the game never presented a frame"; exit 1; }
grep -q '^recorded 900 steps' "$work/play.out" || { echo "::error::the loop did not play and record all 900 steps"; exit 1; }
cmp "$example/replays/bot-seed5.replay" "$work/again.replay"

echo "=== lyric-ui native host on Metal ==="
customers="$(build lyric-ui/native/host/examples/customers/lyric.toml customers)"
SDL_VIDEODRIVER=offscreen "$customers" --check lyric-ui/native/host/examples/customers/golden

echo "macOS graphics e2e passed"
