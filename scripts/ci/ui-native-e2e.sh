#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ui-native-e2e.sh: the native lyric-ui host on examples/ui-customers (docs/67 G10, D203).
#   - the host-free core (layout, protocol client, interaction) is tested with `lyric test`, and the
#     customers example (whose composition now lives in Customers.App) still builds and tests;
#   - the customers example is built for --target native from its own, unchanged packages;
#   - `--check` drives it headless with scripted window events (a link click, typing over a
#     selection, clipboard copy and paste, an input-method composition, saving, the toast) and
#     compares frames drawn by wgpu-native on lavapipe with the golden images;
#   - it then runs in a window on an X server (Xvfb): a screenshot shows the customer list, a real
#     mouse click on a customer opens the edit screen, and real typing changes the name.
#
# Needs SDL3 built with --x11 (scripts/ci/build-sdl3.sh), xvfb, x11-apps, xdotool, imagemagick, lavapipe,
# FreeType/HarfBuzz and DejaVu fonts.  It does not need libwebview: only the desktop host calls it, and a
# dependency package is lowered by reachability (#8429), so this app never links it (checked below).
# Usage: LYRIC_BIN=<lyric> SDL3_PREFIX=<prefix> bash scripts/ci/ui-native-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"
: "${SDL3_PREFIX:?SDL3_PREFIX must name a prefix holding an X11-enabled SDL3}"
export PKG_CONFIG_PATH="$SDL3_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$SDL3_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

for tool in xvfb-run xwd convert xdotool; do
  command -v "$tool" >/dev/null || { echo "::error::$tool is not installed (xvfb, x11-apps, imagemagick, xdotool)"; exit 1; }
done
icd=""
for candidate in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
  if [ -f "$candidate" ]; then icd="$candidate"; break; fi
done
[ -n "$icd" ] || { echo "::error::no lavapipe Vulkan ICD (mesa-vulkan-drivers) on the runner"; exit 1; }
export VK_ICD_FILENAMES="$icd"
export LYRIC_UI_FONT="${LYRIC_UI_FONT:-/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf}"
export LYRIC_UI_FONT_BOLD="${LYRIC_UI_FONT_BOLD:-/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "=== Ui.Native.Core tests ==="
"$LYRIC_BIN" test --manifest lyric-ui/native/lyric.toml
echo "=== examples/ui-customers tests (composition in Customers.App) ==="
"$LYRIC_BIN" test --manifest examples/ui-customers/lyric.toml

manifest=lyric-ui/native/host/examples/customers/lyric.toml
golden=lyric-ui/native/host/examples/customers/golden
"$LYRIC_BIN" restore --manifest "$manifest"
"$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/customers"

echo "=== the app does not link libwebview (dependency packages are lowered by reachability, #8429) ==="
if readelf -d "$work/customers" | grep -q 'NEEDED.*webview'; then
  echo "::error::the native host links libwebview although only the desktop host uses it"
  readelf -d "$work/customers" | grep NEEDED
  exit 1
fi
if nm -D "$work/customers" 2>/dev/null | grep -q 'webview_'; then
  echo "::error::the native host references a webview_ symbol"
  exit 1
fi

echo "=== scripted headless run against the golden frames ==="
SDL_VIDEODRIVER=offscreen "$work/customers" --check "$golden"

cat > "$work/session.sh" <<SESSION
#!/usr/bin/env bash
set -euo pipefail
"$work/customers" > "$work/live.out" 2>&1 &
pid=\$!
for _ in \$(seq 1 150); do
  grep -q '^presented' "$work/live.out" 2>/dev/null && break
  kill -0 \$pid 2>/dev/null || break
  sleep 0.1
done
sleep 1
# No window manager runs here, so SDL centres the window; positions are given relative to it.
win=\$(xdotool search --onlyvisible --pid \$pid | head -1)
xwd -root -silent | convert xwd:- -depth 8 rgb:"$work/list.rgb"
# A real click on the first customer's link, then real typing into the name field.
xdotool mousemove --window \$win 60 120 click 1
sleep 1.5
xwd -root -silent | convert xwd:- -depth 8 rgb:"$work/edit.rgb"
xdotool mousemove --window \$win 300 180 click 1
sleep 0.3
xdotool key ctrl+a
xdotool type --delay 40 "Typed Live"
sleep 0.5
xwd -root -silent | convert xwd:- -depth 8 rgb:"$work/typed.rgb"
kill \$pid 2>/dev/null || true
wait \$pid 2>/dev/null || true
SESSION
chmod +x "$work/session.sh"

echo "=== the customers example in an X11 window ==="
SDL_VIDEODRIVER=x11 xvfb-run -a -s "-screen 0 1280x800x24" "$work/session.sh"
cat "$work/live.out"
grep -q '^presented' "$work/live.out" || { echo "::error::the native host never presented a frame"; exit 1; }

python3 -I - "$work" <<'PY'
import sys
w, h = 1280, 800
def load(name):
    data = open("%s/%s.rgb" % (sys.argv[1], name), "rb").read()
    if len(data) != w * h * 3:
        sys.exit("unexpected screenshot size for %s: %d" % (name, len(data)))
    return data
def count(data, pred):
    return sum(1 for i in range(0, len(data), 3) if pred(data[i], data[i + 1], data[i + 2]))
light = load("list"); edit = load("edit"); typed = load("typed")
surface = lambda r, g, b: (r, g, b) == (255, 255, 255)
ink = lambda r, g, b: r < 90 and g < 90 and b < 100
print("list: %d surface pixels, %d ink pixels" % (count(light, surface), count(light, ink)))
print("edit: %d surface pixels, %d ink pixels" % (count(edit, surface), count(edit, ink)))
if count(light, ink) < 800:
    sys.exit("the list screen shows no text")
# The edit screen draws white input boxes and cards; the list screen is a grid whose cells are white too,
# so the screens are told apart by their pixels changing as a whole.
changed = sum(1 for i in range(0, len(light), 3 * 7) if light[i:i + 3] != edit[i:i + 3])
if changed < 2000:
    sys.exit("the click did not change the screen (%d sampled pixels differ)" % changed)
changed2 = sum(1 for i in range(0, len(edit), 3 * 3) if edit[i:i + 3] != typed[i:i + 3])
if changed2 < 300:
    sys.exit("typing did not change the screen (%d sampled pixels differ)" % changed2)
print("the live window reacted to a click (%d) and to typing (%d)" % (changed, changed2))
PY
echo "native lyric-ui e2e passed"
