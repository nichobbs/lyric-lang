#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch-wasmtime-capi.sh — download the wasmtime C API release that the
# in-process plugin host loads (docs/69 §9.3), verify it, and print the
# directory it unpacked to.
#
#   capi="$(bash scripts/ci/fetch-wasmtime-capi.sh)"
#   export LYRIC_WASMTIME_LIB="$capi/lib/libwasmtime.so"
#
# Pinned to wasmtime 49.0.3, the version whose headers are vendored in
# lyric-rt/third_party/wasmtime; each platform's tarball is checked against
# its SHA-256 before it is unpacked.  The download is cached under
# $LYRIC_WASM_TOOLCACHE (default $RUNNER_TEMP/wasm-tools, falling back to a
# temporary directory), the cache scripts/ci/wasm32-wasi-rt-tests.sh uses.
# ---------------------------------------------------------------------------
set -euo pipefail

WASMTIME_VERSION="49.0.3"

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)
    platform="x86_64-linux"
    sha256="49c9641ac1f6158ed90404115315b36a9ae68338acda16fcf00f0819622ccd97" ;;
  Linux-aarch64|Linux-arm64)
    platform="aarch64-linux"
    sha256="fb9c1a101c092cd3b4536ddb4c68ae31ad70d78bbdbc408d0e007f05a2fdd409" ;;
  Darwin-x86_64)
    platform="x86_64-macos"
    sha256="6d8749e2e0ea1360832c6b0fac76804e74f7ad4ff20ea18cc0f66f9195991313" ;;
  Darwin-arm64)
    platform="aarch64-macos"
    sha256="0c853eb1715b3730304f926d111d4b4a3605b961c5693753bfeeb6b19332c41b" ;;
  *)
    echo "fetch-wasmtime-capi.sh: no pinned wasmtime C API for $(uname -s) $(uname -m)" >&2
    exit 1 ;;
esac

tools="${LYRIC_WASM_TOOLCACHE:-${RUNNER_TEMP:-$(mktemp -d)}/wasm-tools}"
mkdir -p "$tools"
name="wasmtime-v${WASMTIME_VERSION}-${platform}-c-api"
dir="$tools/$name"

if [ ! -f "$dir/lib/libwasmtime.a" ]; then
  tarball="$tools/$name.tar.xz"
  if [ ! -f "$tarball" ]; then
    curl -fsSL "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/${name}.tar.xz" \
      -o "$tarball.part"
    echo "$sha256  $tarball.part" | sha256sum -c - >&2
    mv "$tarball.part" "$tarball"
  fi
  tar -xJf "$tarball" -C "$tools"
fi

echo "$dir"
