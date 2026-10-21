#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gpu-examples-e2e.sh: lyric-gpu's examples on the native backend, against
# wgpu-native on a software Vulkan device (docs/67 G5).
#   - compute: a WGSL compute pass doubles a thousand integers and every one
#     is read back and checked;
#   - triangle and quad (a textured quad from a vertex buffer, a uniform buffer, a texture
#     and a sampler): a render pass draws into an offscreen target whose pixels are
#     compared with the checked-in golden image, within a per-channel and a
#     differing-pixel tolerance (a software and a hardware rasteriser place
#     edge pixels differently).
# The wgpu-native library comes from lyric-gpu's pinned prebuilt archives via
# `lyric restore`.  Lavapipe (mesa-vulkan-drivers) is the Vulkan device.
#
# Usage: LYRIC_BIN=<path to lyric> bash scripts/ci/gpu-examples-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"

icd=""
for candidate in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
  if [ -f "$candidate" ]; then icd="$candidate"; break; fi
done
if [ -z "$icd" ]; then
  sudo apt-get update -qq && sudo apt-get install -y -qq mesa-vulkan-drivers
  for candidate in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.*.json; do
    if [ -f "$candidate" ]; then icd="$candidate"; break; fi
  done
fi
[ -n "$icd" ] || { echo "::error::no lavapipe Vulkan ICD (mesa-vulkan-drivers) on the runner"; exit 1; }
export VK_ICD_FILENAMES="$icd"

# The struct sizes gpu.l packs into C arrays match the headers.
clang -fsyntax-only -I lyric-gpu/native lyric-gpu/native/wgpu_layout_check.c

# The kernel bindings are generated; they must match the headers and allow-list.
(cd lyric-gpu && "$LYRIC_BIN" bindgen native/include/wgpu_bindings.h --package Gpu.Kernel.Wgpu \
  --allow native/wgpu.allow --library wgpu_native-release -o src/_kernel/wgpu.l --check)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for example in compute triangle quad; do
  manifest="lyric-gpu/examples/$example/lyric.toml"
  "$LYRIC_BIN" restore --manifest "$manifest"
  "$LYRIC_BIN" build --target native --manifest "$manifest" -o "$work/$example"
done

echo "=== lyric-gpu compute ==="
out="$("$work/compute")"
echo "$out"
echo "$out" | grep -q "checked 1000 values, wrong=0"
echo "$out" | grep -q "invalid shader rejected: with a message"

echo "=== lyric-gpu triangle ==="
"$work/triangle" lyric-gpu/examples/triangle/golden/triangle-64.rgba

echo "=== lyric-gpu quad ==="
"$work/quad" lyric-gpu/examples/quad/golden/quad-64.rgba
