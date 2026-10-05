#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ui-desktop-e2e.sh — end-to-end test for lyric-ui's desktop host (docs/65
# §10.2, U5).  Builds lyric-ui/e2e/desktop-probe on the requested target and
# runs it under a virtual X display: the probe opens a real webview window,
# and passes only when the UI runtime inside the window has connected its
# session and reported its data grid's viewport, whose effect prints a
# marker and closes the window (exit status 0).
#
# Usage: scripts/ci/ui-desktop-e2e.sh [--target dotnet|jvm|native]
# The CLI is $LYRIC_CLI_PATH, or the AOT build for $BUILD_CONFIG.  A JVM run
# needs $LYRIC_MAVEN_RESOLVER (see ui-jvm-suites.sh); a native run needs clang
# and builds its own lyric_rt.a.  Installs WebKitGTK,
# Xvfb and the webview library when they are missing (Debian/Ubuntu).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

target="dotnet"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    *) echo "ui-desktop-e2e: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$target" in
  dotnet|jvm|native) ;;
  *) echo "ui-desktop-e2e: --target must be dotnet, jvm or native, got '$target'" >&2; exit 2 ;;
esac

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_CLI_PATH:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric CLI not found at $lyric_bin" >&2
  exit 1
fi

sudo_cmd=""
if [ "$(id -u)" != "0" ]; then sudo_cmd="sudo"; fi
if ! pkg-config --exists webkit2gtk-4.1 || ! command -v xvfb-run >/dev/null || ! command -v cmake >/dev/null; then
  # Serialized: other steps of the same job may run apt-get concurrently.
  flock /tmp/lyric-ci-apt.lock -c "$sudo_cmd apt-get update -qq && $sudo_cmd apt-get install -y -qq libwebkit2gtk-4.1-dev xvfb xauth cmake g++ pkg-config" >/dev/null
fi
if [ ! -e /usr/local/lib/libwebview.so ]; then
  flock /tmp/lyric-ci-webview.lock -c "[ -e /usr/local/lib/libwebview.so ] || bash scripts/ci/install-webview.sh"
fi
export LD_LIBRARY_PATH="/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

manifest="lyric-ui/e2e/desktop-probe/lyric.toml"
# On dotnet the probe links the library's built assembly (lyric-ui/bin);
# the JVM build compiles its path dependencies from source.
if [ "$target" = "dotnet" ]; then
  "$lyric_bin" build --manifest lyric-ui/lyric.toml
fi
if [ "$target" = "jvm" ]; then
  "$lyric_bin" restore --manifest "$PWD/$manifest"
fi
if [ "$target" = "native" ]; then
  # A private lyric_rt.a: the dev tree's lyric-rt/build may not exist yet or
  # may be mid-rebuild when a background step links.
  rt_build_dir="$(mktemp -d)/lyric-rt-build"
  make -C lyric-rt BUILD="$rt_build_dir" >/dev/null
  export LYRIC_RT_PATH="$rt_build_dir/lyric_rt.a"
  # The example application links the same library (#8155).
  "$lyric_bin" build --manifest examples/ui-customers/lyric.toml --target native
fi
"$lyric_bin" build --manifest "$manifest" --target "$target"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
status=0
timeout 180 xvfb-run -a "$lyric_bin" run --manifest "$manifest" --target "$target" > "$log" 2>&1 || status=$?
if [ "$status" -ne 0 ] || ! grep -q "desktop-probe: the window reported rows 0+" "$log"; then
  echo "::error::the desktop probe did not complete on $target (exit $status)" >&2
  cat "$log" >&2
  exit 1
fi
grep "desktop-probe:" "$log"
echo "ui-desktop-e2e: the desktop host ran end to end on $target"
