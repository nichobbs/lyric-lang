# D373 - `lyric-gpu`: adapters chosen for a surface; pipelines stay synchronous

**Status:** accepted, implemented for `--target native` (docs/67 phase G5, #8404); extends D197, D317 and D371,
resolves D197 item 4

## Decision

1. **`SurfaceSource`.** A union of the window-system handles a surface presents to: `XlibSource(display, window)`,
   `WaylandSource(display, surface)`, `WindowsSource(instance, hwnd)` and `MetalSource(layer)`. `createSurface(d,
   source)` makes a surface on an open device; `createXlibSurface`, `createWaylandSurface`, `createWindowsSurface` and
   `createMetalSurface` remain as the per-system spellings of it.
2. **`withDeviceFor(source, body)`.** Creates the instance, then the surface, then requests the adapter with the
   surface as `compatibleSurface`, so on a machine with more than one GPU the device is one that can present to the
   window; `withDevice` keeps taking the first adapter for headless work. `body` gets the device and the unconfigured
   surface and owns the surface (configures and releases it). On an early `Err` (no adapter can present to the window,
   a timeout, a device that will not open) the surface is released before the instance, with the rest of D371 item 5.
3. **`GpuWindow.withWindowDevice(window, mode, body)`.** Takes the window's source (`GpuWindow.sourceFor`), opens the
   device with `withDeviceFor`, configures the surface at the window's pixel size with the present mode, and runs
   `body` with both. The window example, `Game.Run` and the native UI host open their devices this way;
   `GpuWindow.surfaceFor` is now `createSurface` over `sourceFor`, for a surface recreated on an open device.
4. **The window example asks for `Mailbox`.** It prints the mode the surface accepted, and `gpu-window-e2e.sh` checks
   that it reports `Mailbox` or the `Fifo` fallback, so the present-mode path of D371 item 7 runs in CI (lavapipe
   under Xvfb offers `Mailbox`).
5. **No asynchronous pipeline creation.** wgpu-native 29 does not implement `wgpuDeviceCreateRenderPipelineAsync` or
   `wgpuDeviceCreateComputePipelineAsync`: both panic with "not implemented" (`src/unimplemented.rs`), verified on
   lavapipe. `Gpu` creates pipelines synchronously, and asynchronous creation waits for wgpu-native to implement the
   two functions.
