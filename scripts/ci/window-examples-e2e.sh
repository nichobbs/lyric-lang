#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# window-examples-e2e.sh: lyric-window against SDL3's headless drivers (docs/67 G4).
#   - the event offsets and flag constants window.l spells out are compiled
#     against SDL's headers (a mismatch is a compile error);
#   - the generated kernel bindings match the headers and the allow-list;
#   - the demo opens a window on the `offscreen` video driver, reads back posted
#     key, mouse and quit events, resizes, round-trips the clipboard, measures
#     time, and plays a tone through the `disk` audio driver, whose output file
#     is checked for the samples.
#
# Usage: LYRIC_BIN=<lyric> SDL3_PREFIX=<prefix with SDL3> bash scripts/ci/window-examples-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"
: "${SDL3_PREFIX:?SDL3_PREFIX must name a prefix holding SDL3}"
export PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$SDL3_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

clang -fsyntax-only -I "$SDL3_PREFIX/include" lyric-window/native/sdl_layout_check.c

(cd lyric-window && "$LYRIC_BIN" bindgen native/sdl_bindings.h --package Window.Kernel.Sdl \
  --allow native/sdl.allow --library SDL3 -o src/_kernel/sdl.l -I "$SDL3_PREFIX/include" --check)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
"$LYRIC_BIN" build --target native --manifest lyric-window/examples/demo/lyric.toml -o "$work/demo"

echo "=== lyric-window demo ==="
out="$(SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=disk SDL_AUDIO_DISK_OUTPUT_FILE="$work/audio.raw" "$work/demo" 2>/dev/null)"
echo "$out"
for expected in \
  "window: 320x200" \
  "event: key-down 97 scancode 4 mods 1 repeat false" \
  "event: key-up 97" \
  "event: motion 10.5,20.25 rel 1.5,-2" \
  "event: button-down 1 at 10.5,20.25 clicks 2" \
  "event: wheel 0,3" \
  "event: quit" \
  "window now: 400x300" \
  "native window: unavailable" \
  "clipboard: héllo clipboard" \
  "time advanced: true" \
  "audio queued after playback: 0" \
  "done"; do
  echo "$out" | grep -qxF "$expected" || { echo "::error::demo output lacks: $expected"; exit 1; }
done

python3 -I - "$work/audio.raw" <<'PY'
import struct, sys
data = open(sys.argv[1], "rb").read()
samples = struct.unpack("<%df" % (len(data) // 4), data)
loud = [s for s in samples if abs(abs(s) - 0.25) < 1e-6]
if len(loud) < 24000:
    sys.exit("expected 24000 samples of the tone in the disk audio output, found %d" % len(loud))
print("audio output: %d samples, %d of them the tone" % (len(samples), len(loud)))
PY
