# D375 - `lyric-gpu`: indexed draws, depth, culling, mipmaps, and adapters chosen for a surface

**Status:** accepted, implemented for `--target native` (docs/67 phase G5, #8404); extends D196, D197, D317 and D374,
resolves D197 item 4

## Decision

1. **Indexed draws.** `Draw` gains `indices: Option[Indices]`; `Indices` is a buffer (`usageIndex`, written with
   `writeInts`) and a count of 32-bit indices. With indices the draw is `drawIndexed` and `vertexCount` is unused.
   Indices are always 32-bit: 16-bit indices would need a 2-byte write path, and WebGPU's 4-byte write alignment would
   force padding on callers for a saving no current consumer needs. `render` rejects an index count the buffer cannot
   hold before encoding.
2. **A pipeline descriptor.** `RenderPipelineDesc` carries everything a render pipeline is built from, adding
   `depthTest` and `cullBack`; `createRenderPipelineFrom` builds from it, and `createRenderPipeline` keeps its
   signature as the no-depth, no-culling case, so existing callers do not change. A record is used instead of more
   positional parameters because the next options (depth bias, topology, multisampling) extend it without another
   signature change.
3. **Depth.** `createDepthTarget` makes a `Depth32Float` buffer; a `depthTest` pipeline writes depth and passes
   `Less`. `renderWithDepth` clears the depth buffer to 1.0 and rejects a depth target whose size differs from the
   colour target's. Every pipeline in such a pass must have `depthTest`; a mismatch is a wgpu validation error, which
   the call's error scope (D374) returns.
4. **Culling.** `cullBack` culls clockwise triangles (front faces are counter-clockwise, as before).
5. **Mipmaps.** `createMipmappedTexture` creates `mipLevelCount(width, height)` levels and fills each from the one above
   with a 2x2 box filter on the CPU (rounded to nearest; an odd last row or column is folded into its neighbour), and
   `writeTexture` rebuilds the chain for a mipmapped texture. `Texture.mipLevels` records the count. A linear
   `createSampler` now also filters between mip levels (`mipmapFilter = Linear`), which changes nothing for a
   single-level texture. CPU generation was chosen over a GPU blit pass: it is deterministic across Vulkan, Metal and
   D3D12, so one golden image serves all three, and it needs no extra pipeline per texture format.
6. **Test.** `lyric-gpu/examples/layers` draws a near red square before an overlapping far green one, a clockwise blue
   square, and a 64x64 texture of one white column in four on a 16x16 square, and checks at sample pixels that depth
   keeps red in front, the blue square is culled, and the stripes show the mipmap average (64) rather than the
   unmipped sample (0); each check fails when its feature is turned off. It then compares the image with
   `golden/layers-64.rgba`. It runs in `gpu-examples-e2e.sh` (lavapipe), `macos-graphics-e2e.sh` (Metal) and
   `windows-graphics-e2e.sh` (WARP).
7. **`SurfaceSource`.** A union of the window-system handles a surface presents to: `XlibSource(display, window)`,
   `WaylandSource(display, surface)`, `WindowsSource(instance, hwnd)` and `MetalSource(layer)`. `createSurface(d,
   source)` makes a surface on an open device; `createXlibSurface`, `createWaylandSurface`, `createWindowsSurface` and
   `createMetalSurface` remain as the per-system spellings of it.
8. **`withDeviceFor(source, body)`.** Creates the instance, then the surface, then requests the adapter with the
   surface as `compatibleSurface`, so on a machine with more than one GPU the device is one that can present to the
   window; `withDevice` keeps taking the first adapter for headless work. `body` gets the device and the unconfigured
   surface and owns the surface (configures and releases it). On an early `Err` (no adapter can present to the window,
   a timeout, a device that will not open) the surface is released before the instance, with the rest of D374 item 5.
9. **`GpuWindow.withWindowDevice(window, mode, body)`.** Takes the window's source (`GpuWindow.sourceFor`), opens the
   device with `withDeviceFor`, configures the surface at the window's pixel size with the present mode, and runs
   `body` with both. The window example, `Game.Run` and the native UI host open their devices this way;
   `GpuWindow.surfaceFor` is now `createSurface` over `sourceFor`, for a surface recreated on an open device.
10. **The window example asks for `Mailbox`.** It prints the mode the surface accepted, and `gpu-window-e2e.sh` checks
   that it reports `Mailbox` or the `Fifo` fallback, so the present-mode path of D374 item 7 runs in CI (lavapipe
   under Xvfb offers `Mailbox`).
11. **No asynchronous pipeline creation.** wgpu-native 29 does not implement `wgpuDeviceCreateRenderPipelineAsync` or
   `wgpuDeviceCreateComputePipelineAsync`: both panic with "not implemented" (`src/unimplemented.rs`), verified on
   lavapipe. `Gpu` creates pipelines synchronously, and asynchronous creation waits for wgpu-native to implement the
   two functions.

## Not in this decision

Stencil, multisampling, depth-only passes and reading depth back; GPU mip generation. `lyric bindgen` support for C
unions (`WGPUNativeDisplayHandle`) and function-pointer results (`wgpuGetProcAddress`) remains on #8404.
