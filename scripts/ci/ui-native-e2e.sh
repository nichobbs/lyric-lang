#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ui-native-e2e.sh: the native lyric-ui host on examples/ui-customers (docs/67 G10, D203).
#   - the host-free core (layout, protocol client, interaction) is tested with `lyric test`, Unicode's
#     BidiCharacterTest.txt and LineBreakTest.txt run against lyric-unicode's algorithms on
#     --target native (lyric-unicode/tests/conformance; dotnet and the JVM in ci.yml), as do ICU
#     74.2's dictionary breaks against lyric-unicode-dict (lyric-unicode-dict/tests/conformance), and the
#     customers example (whose composition now lives in Customers.App) still builds and tests;
#   - the customers example is built for --target native from its own, unchanged packages;
#   - `--check` drives it headless with scripted window events (a link click, typing over a
#     selection, clipboard copy and paste, an input-method composition, a text area of Hebrew and
#     Arabic text with a visual caret and a selection, a name input with Hebrew and a number in it
#     stepped through by screen position and by word, saving, the toast) and
#     compares frames drawn by wgpu-native on lavapipe with the golden images;
#   - it then runs in a window on an X server (Xvfb): a screenshot shows the customer list, a real
#     mouse click on a customer opens the edit screen, and real typing changes the name;
#   - accessibility (lyric-access, AccessKit 0.23.2): the generated AccessKit kernel matches the
#     header, the request layout the adapter reads matches it too, Access.Plan's tests pass, the
#     `--check` run drives assistive-technology requests through the host, the lyric-access smoke
#     program attaches an adapter, and the app runs again in a D-Bus session with the AT-SPI bus
#     enabled while scripts/ci/atspi-smoke.py reads its tree over AT-SPI and clicks, focuses and
#     sets text the way a screen reader does.
#
# Needs SDL3 built with --x11 (scripts/ci/build-sdl3.sh), xvfb, x11-apps, xdotool, imagemagick, lavapipe,
# FreeType/HarfBuzz and DejaVu fonts; at-spi2-core, python3-gi and gir1.2-atspi-2.0 (installed when
# missing).  AccessKit comes from its release archive on Linux x86-64 (`lyric restore`); on other Linux
# hosts it is built from source (scripts/ci/build-accesskit.sh --source, needs cargo) into
# $ACCESSKIT_PREFIX.  It does not need libwebview: only the desktop host calls it, and a
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

echo "=== AccessKit: header, layout and generated kernel ==="
accesskit_prefix="${ACCESSKIT_PREFIX:-$work/accesskit}"
if [ "$(uname -m)" = x86_64 ]; then
  bash scripts/ci/build-accesskit.sh "$accesskit_prefix"
else
  # The release archive has no Linux library for this architecture: lyric-access finds a source
  # build with pkg-config.
  bash scripts/ci/build-accesskit.sh --source "$accesskit_prefix"
  export PKG_CONFIG_PATH="$accesskit_prefix/lib/pkgconfig:$PKG_CONFIG_PATH"
  export LD_LIBRARY_PATH="$accesskit_prefix/lib:$LD_LIBRARY_PATH"
fi
cc -fsyntax-only -I "$accesskit_prefix/include" lyric-access/platform/native/accesskit_layout_check.c
(cd lyric-access/platform && "$LYRIC_BIN" bindgen native/accesskit_bindings.h --package Access.Kernel.Accesskit \
  --allow native/accesskit.allow --library accesskit -o src/_kernel/accesskit_linux.l \
  --cfg 'target_os = "linux"' --check -I "$accesskit_prefix/include")
echo "=== Access.Plan tests ==="
"$LYRIC_BIN" test --manifest lyric-access/lyric.toml

echo "=== Ui.Native.Core tests ==="
"$LYRIC_BIN" test --manifest lyric-ui/native/lyric.toml
echo "=== lyric-unicode: Unicode's conformance suites (BidiCharacterTest.txt, LineBreakTest.txt 15.1) on native ==="
"$LYRIC_BIN" build --target native --manifest lyric-unicode/tests/conformance/lyric.toml -o "$work/unicode-conformance"
"$work/unicode-conformance"
echo "=== lyric-unicode-dict: ICU 74.2's dictionary line and word breaks on native ==="
"$LYRIC_BIN" build --target native --manifest lyric-unicode-dict/tests/conformance/lyric.toml -o "$work/dictionary-conformance"
"$work/dictionary-conformance"
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

echo "=== scripted headless run against the golden frames, and assistive-technology requests ==="
check_out="$(SDL_VIDEODRIVER=offscreen "$work/customers" --check "$golden")"
echo "$check_out"
echo "$check_out" | grep -q "^native ui accessibility check passed" || { echo "::error::the accessibility scenario did not pass"; exit 1; }

echo "=== lyric-access smoke: an adapter on a window ==="
smoke=lyric-access/platform/examples/smoke/lyric.toml
"$LYRIC_BIN" restore --manifest "$smoke"
"$LYRIC_BIN" build --target native --manifest "$smoke" -o "$work/access-smoke"
smoke_out="$(SDL_VIDEODRIVER=offscreen "$work/access-smoke")"
echo "$smoke_out"
echo "$smoke_out" | grep -q "^adapter: detached" || { echo "::error::the lyric-access smoke program failed"; exit 1; }

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
echo "=== the customers example over AT-SPI (D-Bus session, Xvfb) ==="
if ! command -v dbus-run-session >/dev/null || ! command -v gdbus >/dev/null || [ ! -x /usr/libexec/at-spi-bus-launcher ]; then
  bash scripts/ci/install-tool.sh apt at-spi2-core dbus libglib2.0-bin python3-gi gir1.2-atspi-2.0
fi
atspi_py=""
for candidate in /usr/bin/python3 /usr/bin/python3.12 /usr/bin/python3.13 /usr/bin/python3.11 python3; do
  if command -v "$candidate" >/dev/null && "$candidate" -I -c "import gi; gi.require_version('Atspi', '2.0'); from gi.repository import Atspi" 2>/dev/null; then
    atspi_py="$candidate"
    break
  fi
done
[ -n "$atspi_py" ] || {
  bash scripts/ci/install-tool.sh apt python3-gi gir1.2-atspi-2.0
  atspi_py=/usr/bin/python3
}

cat > "$work/a11y-session.sh" <<SESSION
#!/usr/bin/env bash
set -uo pipefail
# The AT-SPI bus, enabled as a screen reader enables it: AccessKit's adapter stays idle until
# org.a11y.Status.IsEnabled is true.
/usr/libexec/at-spi-bus-launcher --launch-immediately > "$work/a11y-bus.log" 2>&1 &
for _ in \$(seq 1 100); do
  gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus --method org.a11y.Bus.GetAddress >/dev/null 2>&1 && break
  sleep 0.1
done
gdbus call --session --dest org.a11y.Bus --object-path /org/a11y/bus \\
  --method org.freedesktop.DBus.Properties.Set org.a11y.Status IsEnabled '<true>' >/dev/null
"$work/customers" > "$work/a11y-app.out" 2>&1 &
pid=\$!
for _ in \$(seq 1 150); do
  grep -q '^presented' "$work/a11y-app.out" 2>/dev/null && break
  kill -0 \$pid 2>/dev/null || break
  sleep 0.1
done
"$atspi_py" -I "$REPO_ROOT/scripts/ci/atspi-smoke.py" customers "Acme Pty Ltd"
rc=\$?
kill \$pid 2>/dev/null || true
wait \$pid 2>/dev/null || true
exit \$rc
SESSION
chmod +x "$work/a11y-session.sh"
if ! SDL_VIDEODRIVER=x11 xvfb-run -a -s "-screen 0 1280x800x24" dbus-run-session -- "$work/a11y-session.sh"; then
  echo "--- the app's output ---"
  cat "$work/a11y-app.out" || true
  echo "::error::the AT-SPI smoke test failed"
  exit 1
fi

echo "native lyric-ui e2e passed"
