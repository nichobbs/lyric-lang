#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# release-native-smoke.sh — an unpacked release archive builds and runs a
# native program on its own (#8454).
#
# `lyric build --target native` compiles the stdlib from source and links the
# runtime archive, so a release archive carries both: `lib/std/` (the
# contents of lyric-stdlib/std, with the `_kernel_native/` twins) and
# `lib/lyric_rt.a` (`lib/lyric_rt-<triple>.lib` on Windows).  This builds a
# hello-world from an empty directory with none of LYRIC_STD_PATH,
# LYRIC_RT_PATH, LYRIC_RT_WINDOWS_PATH or LYRIC_RT_WINDOWS_MD_PATH set, so the
# build can find them only through the archive's own layout.
#
# The archive must be unpacked outside any checkout: inside one, the
# compiler's walk-up from the binary would find the repository's stdlib and
# the smoke test would pass without the archive's copy.
#
# Usage: bash scripts/ci/release-native-smoke.sh <unpacked-archive-dir> [triple]
#   triple: pass x86_64-pc-windows-msvc for the Windows archive.
# ---------------------------------------------------------------------------
set -euo pipefail

root="${1:?usage: release-native-smoke.sh <unpacked-archive-dir> [triple]}"
triple="${2:-}"
root="$(cd "$root" && pwd)"

exe="$root/lyric"
ext=""
if [ -f "$root/lyric.exe" ]; then
  exe="$root/lyric.exe"
  ext=".exe"
fi
[ -f "$exe" ] || { echo "::error::no lyric binary in $root"; exit 1; }

dir="$root"
while [ "$dir" != "/" ] && [ -n "$dir" ]; do
  if [ -d "$dir/lyric-stdlib/std" ]; then
    echo "::error::$root is inside a checkout ($dir); unpack the archive elsewhere so the walk-up cannot find the repository's stdlib"
    exit 1
  fi
  parent="$(dirname "$dir")"
  [ "$parent" = "$dir" ] && break
  dir="$parent"
done

[ -d "$root/lib/std/_kernel_native" ] || { echo "::error::the archive has no lib/std/_kernel_native (stdlib sources)"; exit 1; }
if [ -n "$triple" ] && case "$triple" in *windows*) true ;; *) false ;; esac; then
  [ -f "$root/lib/lyric_rt-$triple.lib" ] || { echo "::error::the archive has no lib/lyric_rt-$triple.lib"; exit 1; }
else
  [ -f "$root/lib/lyric_rt.a" ] || { echo "::error::the archive has no lib/lyric_rt.a"; exit 1; }
fi

work="$(mktemp -d)"
cat > "$work/hello.l" <<'LYRIC'
package ReleaseNativeSmoke

import Std.Collections

func main(): Int {
  val xs: List[Int] = newList()
  xs.add(40)
  xs.add(2)
  println("hello from native " + toString(xs[0] + xs[1]))
  0
}
LYRIC

args=(build --target native hello.l -o "hello$ext")
if [ -n "$triple" ]; then
  args+=(--triple "$triple")
fi
(
  cd "$work"
  env -u LYRIC_STD_PATH -u LYRIC_RT_PATH -u LYRIC_RT_WINDOWS_PATH -u LYRIC_RT_WINDOWS_MD_PATH "$exe" "${args[@]}"
  got="$(./hello$ext | tr -d '\r')"
  if [ "$got" != "hello from native 42" ]; then
    echo "::error::release-layout native build printed '$got', expected 'hello from native 42'"
    exit 1
  fi
)
echo "OK: the unpacked archive builds and runs a native program with no environment overrides (#8454)."
