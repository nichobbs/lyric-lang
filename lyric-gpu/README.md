# lyric-gpu

WebGPU compute and rendering for `--target native`, over wgpu-native (docs/67 G5).

- `Gpu.Kernel.Wgpu` is `lyric bindgen` output from `webgpu.h` and wgpu-native's `wgpu.h`; never edit it. Regenerate
  from `native/wgpu.allow` with the command in `scripts/ci/gpu-examples-e2e.sh`.
- `Gpu` is the safe surface. Every GPU object is an opaque handle in a record; a `Device` lives for one `withDevice`
  call; errors wgpu reports through its uncaptured-error callback come back as `Err` from the call that caused them.

## Build

`lyric restore` fetches the pinned wgpu-native 0.32.0 library for the platform (Linux x86-64 and arm64, macOS arm64 and
x86-64, Windows x86-64). On macOS a program that links it runs from a `.app` bundle, which an application opts into with
a `[native.app]` table in its manifest; the examples all do.

## Examples

`examples/compute` (a compute pass), `triangle` and `quad` (offscreen render, checked against golden images) and
`window` (a triangle in an SDL3 window). Headless runs need a Vulkan device on Linux (lavapipe in CI) and Metal on macOS.

## Surfaces

`createXlibSurface`, `createWaylandSurface`, `createWindowsSurface` and `createMetalSurface` take the handles
`lyric-window` exposes; `GpuWindow.surfaceFor` in `lyric-gpu-window` picks the right one. Configure a surface with the
window's `pixelSize`. Acquire frames with `tryAcquireFrame`: it returns no frame (not an error) for an occluded or
not-yet-visible window, and `Err` only when the surface must be reconfigured (after a resize). `presentFrame` shows a
frame; `discardFrame` releases one that was not drawn.
