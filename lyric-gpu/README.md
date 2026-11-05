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

Pipelines are created synchronously: wgpu-native 29 does not implement `wgpuDeviceCreateRenderPipelineAsync` or
`wgpuDeviceCreateComputePipelineAsync` (both panic with "not implemented").

## Examples

`examples/compute` (a compute pass), `triangle`, `quad` and `layers` (offscreen renders checked against golden images;
`layers` covers indexed draws, a depth test, back-face culling and a mipmapped texture) and `window` (a triangle in an
SDL3 window). Headless runs need a Vulkan device on Linux (lavapipe in CI) and Metal on macOS.

## Drawing

`render` clears a target and runs a list of `Draw`s. A draw reads its vertices from vertex buffers, or through 32-bit
indices when its `indices` is set (`Indices`, a buffer with `usageIndex`). `createRenderPipeline` builds a pipeline
without depth or culling; `createRenderPipelineFrom` takes a `RenderPipelineDesc` with `depthTest` (draw only nearer
fragments, which needs `renderWithDepth` and a `createDepthTarget` of the target's size) and `cullBack` (skip
clockwise triangles). `createMipmappedTexture` builds a texture's full mip chain on the CPU with a 2x2 box filter, and
`writeTexture` rebuilds it; a `createSampler(d, true)` sampler blends between the levels.

## Surfaces

A `SurfaceSource` is the window-system handle a surface presents to (X11, Wayland, Win32 or a macOS `CAMetalLayer`), as
`lyric-window` exposes them; `createSurface` makes a surface from one (`createXlibSurface` and its siblings are the
same per window system). `withDeviceFor(source, body)` opens the device on an adapter that can present to the source,
which matters with more than one GPU, and hands `body` the device and the surface. In `lyric-gpu-window`,
`GpuWindow.withWindowDevice(window, mode, body)` does that for a window and configures the surface first, and
`GpuWindow.surfaceFor` makes another surface for a window on an open device. Configure a surface with the
window's `pixelSize`. Acquire frames with `tryAcquireFrame`: it returns no frame (not an error) for an occluded or
not-yet-visible window, and a `FrameError` when the loop must act: `Outdated` (configure the surface again, as after a
resize), `Lost` (create a new surface) or `Failed` (stop). `GpuWindow.recoverSurface` handles the first two for a
window, and `GpuWindow.configuredSurfaceFor` creates and configures one. `presentFrame` shows a frame; `discardFrame`
releases one that was not drawn. Frames present vsynced (`Fifo`); `withPresentMode` asks for `FifoRelaxed`, `Mailbox`
or `Immediate`, and the configured surface's `presentMode` is the mode the surface accepted.
