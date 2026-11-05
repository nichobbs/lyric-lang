# lyric-gpu

WebGPU compute and rendering for `--target native`, over wgpu-native (docs/67 G5).

- `Gpu.Kernel.Wgpu` is `lyric bindgen` output from `webgpu.h` and wgpu-native's `wgpu.h`; never edit it. Regenerate
  from `native/wgpu.allow` with the command in `scripts/ci/gpu-examples-e2e.sh`.
- `Gpu` is the safe surface. Every GPU object is an opaque handle in a record; a `Device` lives for one `withDevice`
  call. Every call that can fail returns a `Result` and runs inside wgpu's validation and out-of-memory error scopes,
  so its `Err` is the error that call caused. A shader that does not compile is an `Err` starting `WGSL:` with the
  compiler's line and column. A lost device makes every later call return the reason (`deviceLost`). wgpu-native has
  no internal-error scope, so internal errors and errors wgpu raises outside any call reach `takeError`.

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
not-yet-visible window, and a `FrameError` when the loop must act: `Outdated` (configure the surface again, as after a
resize), `Lost` (create a new surface) or `Failed` (stop). `GpuWindow.recoverSurface` handles the first two for a
window, and `GpuWindow.configuredSurfaceFor` creates and configures one. `presentFrame` shows a frame; `discardFrame`
releases one that was not drawn. Frames present vsynced (`Fifo`); `withPresentMode` asks for `FifoRelaxed`, `Mailbox`
or `Immediate`, and the configured surface's `presentMode` is the mode the surface accepted.
