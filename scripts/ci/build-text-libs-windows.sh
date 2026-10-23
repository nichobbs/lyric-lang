#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-text-libs-windows.sh: build FreeType and HarfBuzz (with its FreeType
# bridge, which lyric-text uses) from pinned release sources into a prefix on
# a Windows host, with CMake, Ninja and clang, for lyric-text's Windows CI
# (docs/67 G9).  Neither project publishes an MSVC build with the bridge, so
# CI builds the releases Ubuntu 24.04 ships (the Linux job's goldens were made
# with them) and writes their pkg-config files, which is how lyric-text finds
# them on every platform.  A developer on Windows uses vcpkg's `freetype` and
# `harfbuzz[freetype]`, whose pkg-config files work the same way.
#
# Usage: bash scripts/ci/build-text-libs-windows.sh <prefix>
# Afterwards: PKG_CONFIG_PATH=<prefix>/lib/pkgconfig; the DLLs are in <prefix>/bin.
# ---------------------------------------------------------------------------
set -euo pipefail

FT_VERSION="2.13.2"
FT_SHA256="12991c4e55c506dd7f9b765933e62fd2be2e06d421505d7950a132e4f1bb484d"
FT_URL="https://downloads.sourceforge.net/project/freetype/freetype2/${FT_VERSION}/freetype-${FT_VERSION}.tar.xz"
HB_VERSION="8.3.0"
HB_SHA256="109501eaeb8bde3eadb25fab4164e993fbace29c3d775bcaa1c1e58e2f15f847"
HB_URL="https://github.com/harfbuzz/harfbuzz/releases/download/${HB_VERSION}/harfbuzz-${HB_VERSION}.tar.xz"

prefix="${1:?usage: build-text-libs-windows.sh <prefix>}"
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"
marker="$prefix/.text-libs-ft$FT_VERSION-hb$HB_VERSION"
if [ -f "$marker" ]; then
  echo "FreeType $FT_VERSION and HarfBuzz $HB_VERSION already built in $prefix"
  exit 0
fi
# CMake and pkg-config read Windows paths.
mprefix="$(cygpath -m "$prefix")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fetch() {
  local url="$1" sha="$2" out="$3"
  curl -fsSL --retry 3 -o "$out" "$url"
  echo "$sha  $out" | sha256sum -c -
}

fetch "$FT_URL" "$FT_SHA256" "$work/freetype.tar.xz"
fetch "$HB_URL" "$HB_SHA256" "$work/harfbuzz.tar.xz"
(cd "$work" && cmake -E tar xf freetype.tar.xz && cmake -E tar xf harfbuzz.tar.xz)

# FreeType alone: no zlib, bzip2, PNG, Brotli or HarfBuzz (the fonts lyric-text
# opens need none of them, and HarfBuzz is built against it below).
cmake -S "$work/freetype-$FT_VERSION" -B "$work/ft-build" -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_INSTALL_PREFIX="$mprefix" \
  -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
cmake --build "$work/ft-build"
cmake --install "$work/ft-build"

cmake -S "$work/harfbuzz-$HB_VERSION" -B "$work/hb-build" -G Ninja \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
  -DCMAKE_INSTALL_PREFIX="$mprefix" -DCMAKE_PREFIX_PATH="$mprefix" \
  -DHB_HAVE_FREETYPE=ON -DHB_BUILD_SUBSET=OFF -DHB_BUILD_UTILS=OFF
cmake --build "$work/hb-build"
cmake --install "$work/hb-build"

for f in bin/freetype.dll lib/freetype.lib bin/harfbuzz.dll lib/harfbuzz.lib include/freetype2/ft2build.h include/harfbuzz/hb-ft.h; do
  [ -f "$prefix/$f" ] || { echo "::error::the text library build did not install $f"; exit 1; }
done

# The pkg-config files, written here so they are the same whatever each
# project's CMake build would generate on Windows.
mkdir -p "$prefix/lib/pkgconfig"
cat > "$prefix/lib/pkgconfig/freetype2.pc" <<PC
prefix=$mprefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: FreeType 2
Description: A free, high-quality, and portable font engine.
Version: 26.1.20
Libs: -L\${libdir} -lfreetype
Cflags: -I\${includedir}/freetype2
PC
cat > "$prefix/lib/pkgconfig/harfbuzz.pc" <<PC
prefix=$mprefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: harfbuzz
Description: HarfBuzz text shaping library
Version: $HB_VERSION
Requires: freetype2
Libs: -L\${libdir} -lharfbuzz
Cflags: -I\${includedir}/harfbuzz
PC
touch "$marker"
echo "FreeType $FT_VERSION and HarfBuzz $HB_VERSION installed in $prefix"
