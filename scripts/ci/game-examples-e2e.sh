#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# game-examples-e2e.sh: lyric-game's Breakout sample (docs/67 G7).
#   - the pure core and the game's rules are tested with `lyric test`, including a checked-in
#     recording that must replay to a pinned state digest;
#   - the same recording is replayed by the native binary with no window: the final state's
#     digest must equal the one the managed targets compute (the game is deterministic across
#     targets), and the last frame, drawn by wgpu-native on lavapipe, must match the golden image;
#   - the game is then played in a window on an X11 server (Xvfb): the recording drives it, a
#     screenshot shows the playfield, and the input the loop recorded while playing must equal
#     the recording that went in.
#
# Needs SDL3 built with --x11 (scripts/ci/build-sdl3.sh), xvfb, x11-apps, imagemagick, lavapipe,
# FreeType and DejaVu fonts (the HUD font is optional for the game, required by the golden image).
# Usage: LYRIC_BIN=<lyric> SDL3_PREFIX=<prefix> bash scripts/ci/game-examples-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"
: "${SDL3_PREFIX:?SDL3_PREFIX must name a prefix holding an X11-enabled SDL3}"
export PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$SDL3_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

for tool in xvfb-run xwd convert; do
  command -v "$tool" >/dev/null || { echo "::error::$tool is not installed (xvfb, x11-apps, imagemagick)"; exit 1; }
done
icd=""
for candidate in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
  if [ -f "$candidate" ]; then icd="$candidate"; break; fi
done
[ -n "$icd" ] || { echo "::error::no lavapipe Vulkan ICD (mesa-vulkan-drivers) on the runner"; exit 1; }
export VK_ICD_FILENAMES="$icd"
export LYRIC_TEXT_FONT_LATIN="${LYRIC_TEXT_FONT_LATIN:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}"
export LYRIC_GAME_ASSETS="lyric-game/examples/breakout/assets"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
example=lyric-game/examples/breakout

echo "=== lyric-game core tests ==="
"$LYRIC_BIN" test --manifest lyric-game/lyric.toml
echo "=== Breakout rules and replay tests ==="
"$LYRIC_BIN" test --manifest "$example/logic/lyric.toml"

manifest="$example/app/lyric.toml"
"$LYRIC_BIN" restore --manifest "$manifest"
"$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/breakout"

digest=784632209
echo "=== headless replay on the native target ==="
"$work/breakout" --check "$example/replays/bot-seed5.replay" "$digest" "$example/replays/golden-final-320x240.rgba"

cat > "$work/session.sh" <<SESSION
#!/usr/bin/env bash
set -euo pipefail
"$work/breakout" --play "$example/replays/bot-seed5.replay" --record "$work/again.replay" > "$work/play.out" 2>&1 &
pid=\$!
for _ in \$(seq 1 100); do
  grep -q '^presented' "$work/play.out" 2>/dev/null && break
  kill -0 \$pid 2>/dev/null || break
  sleep 0.1
done
sleep 1
kill -0 \$pid 2>/dev/null || { echo '::error::the game exited before the screenshot'; exit 1; }
xwd -root -silent | convert xwd:- -depth 8 rgb:"$work/shot.rgb"
wait \$pid
SESSION
chmod +x "$work/session.sh"

echo "=== Breakout in an X11 window ==="
SDL_VIDEODRIVER=x11 SDL_AUDIODRIVER=dummy xvfb-run -a -s "-screen 0 1024x768x24" "$work/session.sh"
cat "$work/play.out"
grep -q '^presented' "$work/play.out" || { echo "::error::the game never presented a frame"; exit 1; }
grep -q '^recorded 900 steps' "$work/play.out" || { echo "::error::the loop did not play and record all 900 steps"; exit 1; }
cmp "$example/replays/bot-seed5.replay" "$work/again.replay" || { echo "::error::the recorded input differs from the recording played"; exit 1; }

python3 -I - "$work/shot.rgb" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if len(data) != 1024 * 768 * 3:
    sys.exit("unexpected screenshot size %d" % len(data))
brick = {(220, 60, 60): 0, (235, 140, 50): 0, (235, 210, 60): 0, (80, 190, 90): 0, (70, 130, 230): 0}
for i in range(0, len(data), 3):
    px = (data[i], data[i + 1], data[i + 2])
    if px in brick:
        brick[px] += 1
print("screenshot brick-colour pixels:", brick)
# Each brick row is a run of 28x10 game units drawn at the window's scale; whatever the
# window decoration, every row must show a solid body of its colour.
if min(brick.values()) < 2000:
    sys.exit("the window does not show the five brick rows")
PY
echo "lyric-game Breakout e2e passed"
