#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# access-platform-e2e.sh: lyric-access on macOS and Windows (docs/67 G10, issue #8489).
# Linux is covered by scripts/ci/ui-native-e2e.sh, which drives the native lyric-ui host over AT-SPI.
#
#   - the request layout the adapter reads, and this platform's generated AccessKit kernel
#     (`lyric bindgen --check`), match AccessKit's header as this platform's compiler sees it;
#   - the lyric-access smoke program (lyric-access/platform/examples/smoke) opens a window,
#     attaches the platform adapter (NSAccessibility on macOS, UI Automation on Windows),
#     publishes a tree and detaches;
#   - on Windows it then waits while scripts/ci/uia-smoke.ps1 finds its button through UI
#     Automation and invokes it, and passes only when that click reaches it through AccessKit.
#     macOS has no such client here: a UI client must be granted the Accessibility permission,
#     which a hosted runner does not give (#8799).
#
# Usage: LYRIC_BIN=<lyric> bash scripts/ci/access-platform-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"

case "$(uname -s)" in
  Darwin)
    variant=macos
    triple="$(uname -m | sed 's/^arm64$/aarch64/')-apple-darwin"
    ;;
  MINGW* | MSYS* | CYGWIN*)
    variant=windows
    triple=x86_64-pc-windows-msvc
    ;;
  *)
    echo "::error::access-platform-e2e.sh runs on macOS and Windows; Linux is scripts/ci/ui-native-e2e.sh"
    exit 1
    ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "=== AccessKit header, request layout and the $variant kernel ==="
bash scripts/ci/build-accesskit.sh "$work/accesskit"
include="$work/accesskit/include"
[ "$variant" = windows ] && include="$(cygpath -m "$include")"
clang -fsyntax-only -I "$include" lyric-access/platform/native/accesskit_layout_check.c
(cd lyric-access/platform && "$LYRIC_BIN" bindgen native/accesskit_bindings.h --package Access.Kernel.Accesskit \
  --allow native/accesskit.allow --library accesskit -o "src/_kernel/accesskit_$variant.l" \
  --cfg "target_os = \"$variant\"" --triple "$triple" --check -I "$include")

echo "=== the lyric-access smoke program ==="
manifest=lyric-access/platform/examples/smoke/lyric.toml
"$LYRIC_BIN" restore --target native --manifest "$manifest"
"$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/access-smoke"

if [ "$variant" = macos ]; then
  exe="$work/access-smoke.app/Contents/MacOS/access-smoke"
  [ -x "$exe" ] || { echo "::error::access-smoke.app was not written"; exit 1; }
  out="$("$exe")"
  echo "$out"
  echo "$out" | grep -q "^adapter: detached" || { echo "::error::the NSAccessibility adapter smoke test failed"; exit 1; }
  echo "lyric-access on macOS passed"
  exit 0
fi

"$work/access-smoke.exe" --wait-click 60 > "$work/smoke.out" 2>&1 &
pid=$!
uia_rc=0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$REPO_ROOT/scripts/ci/uia-smoke.ps1")" || uia_rc=$?
smoke_rc=0
wait "$pid" || smoke_rc=$?
tr -d '\r' < "$work/smoke.out"
if [ "$uia_rc" != 0 ] || [ "$smoke_rc" != 0 ]; then
  echo "::error::the UI Automation smoke test failed (client $uia_rc, program $smoke_rc)"
  exit 1
fi
tr -d '\r' < "$work/smoke.out" | grep -q "^request: click press" || { echo "::error::the click did not reach the program"; exit 1; }
echo "lyric-access on Windows passed"
