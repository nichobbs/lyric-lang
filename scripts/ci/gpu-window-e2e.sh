#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gpu-window-e2e.sh: lyric-window and lyric-gpu together on an X11 server
# (docs/67 G4 + G5).  The window example creates an SDL3 window on the X11
# video driver, builds a wgpu surface from the window's native handles, and
# presents frames of a red triangle on blue.  The script runs it under Xvfb
# with lavapipe as the Vulkan device, takes a screenshot of the display while
# the window is up, and checks the pixel counts of the two colours.
#
# Needs SDL3 built with --x11 (scripts/ci/build-sdl3.sh), xvfb, x11-apps and
# imagemagick.
# Usage: LYRIC_BIN=<lyric> SDL3_PREFIX=<prefix> bash scripts/ci/gpu-window-e2e.sh
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

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
manifest="lyric-gpu/examples/window/lyric.toml"
"$LYRIC_BIN" restore --manifest "$manifest"
"$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/window"

cat > "$work/session.sh" <<SESSION
#!/usr/bin/env bash
set -euo pipefail
"$work/window" 6 > "$work/window.out" 2>&1 &
pid=\$!
for _ in \$(seq 1 100); do
  grep -q '^presented' "$work/window.out" 2>/dev/null && break
  kill -0 \$pid 2>/dev/null || break
  sleep 0.1
done
sleep 1
xwd -root -silent | convert xwd:- -depth 8 rgb:"$work/shot.rgb"
wait \$pid
SESSION
chmod +x "$work/session.sh"

echo "=== lyric-gpu window on X11 ==="
SDL_VIDEODRIVER=x11 xvfb-run -a -s "-screen 0 640x480x24" "$work/session.sh"
cat "$work/window.out"
grep -q '^presented' "$work/window.out" || { echo "::error::the window example never presented a frame"; exit 1; }

python3 -I - "$work/shot.rgb" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if len(data) != 640 * 480 * 3:
    sys.exit("unexpected screenshot size %d" % len(data))
blue = red = 0
for i in range(0, len(data), 3):
    px = data[i:i + 3]
    if px == b"\x00\x00\xff":
        blue += 1
    elif px == b"\xff\x00\x00":
        red += 1
print("screenshot: %d blue pixels, %d red pixels" % (blue, red))
# The 256x256 window shows ~44.7k blue and ~20.8k red pixels (the triangle covers a third of
# the window); the thresholds leave room for a different rasteriser or window decoration.
if blue < 30000 or red < 10000:
    sys.exit("the window does not show the blue field with a red triangle")
PY
