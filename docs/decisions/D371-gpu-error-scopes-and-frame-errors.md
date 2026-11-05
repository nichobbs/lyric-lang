# D371 - `lyric-gpu`: error scopes, device loss, frame errors and present modes

**Status:** accepted, implemented for `--target native` (docs/67 phase G5, #8404); extends D194, D196, D197 and D317,
supersedes D197 item 2 and D317 item 5's "`acquireFrame` keeps its behaviour"

## Decision

1. **Error scopes.** Every `Gpu` call that can fail pushes wgpu's validation and out-of-memory error scopes, makes its
   wgpu calls, and pops them, waiting for each pop with the same wall-clock deadline as every other wgpu callback. The
   error it caused is its own `Err`, so a bad call no longer leaves an error for the next call that happened to read the
   uncaptured-error cell. wgpu-native 29 panics on `WGPUErrorFilter_Internal` ("invalid error filter"), so internal
   errors are not scoped: they still reach the uncaptured-error callback, which keeps the first message and counts the
   rest, and `takeError` reports them as "message (and N more errors)".
2. **Every fallible call returns `Result`.** `createBuffer`, `createRenderTarget`, `createSampler`, `writeInts`,
   `writeBytes` and `writeFloats` now return `Result`. The writes check the offset, the byte count (both multiples of 4,
   as WebGPU requires) and the buffer's size before calling wgpu; `createRenderTarget` and `configureSurface` reject a
   size that is not positive, and `readInts` a count that does not fit the buffer.
3. **WGSL errors.** The shader module is created in a scope of its own, so a shader that does not compile is an `Err`
   starting `WGSL: ` with naga's message, which names the line and column, apart from an error in the pipeline built
   from it. `wgpuShaderModuleGetCompilationInfo` is not used: naga's message already carries the location.
4. **Device loss.** The device-lost callback records the reason and message in the device's error cell (ignoring
   `Destroyed`, which is the device's own release, and `CallbackCancelled`). `deviceLost(d)` returns it, and every
   scoped call, surface creation, `configureSurface` and `tryAcquireFrame` return it as their `Err` once the device is
   lost. A program recovers by leaving `withDevice` and opening a new device.
5. **`withDevice` releases what it acquired.** Every early `Err` (adapter timeout, no adapter, device timeout, device
   open failure) releases the instance, the adapter, any device handle and the error cell first. A panic in `body` ends
   the program without releasing the device (native code does not unwind); the operating system reclaims it.
6. **Frame errors.** `tryAcquireFrame` returns `Result[Option[RenderTarget], FrameError]`: `Ok(None)` for an occluded
   window or a compositor timeout as before, and `Outdated` (configure again), `Lost` (create a new surface) or
   `Failed(message)` (device lost or out of memory: stop). `frameErrorMessage` describes one. `acquireFrame`, which
   turned every one of these into the same `Err` and had no callers, is removed. `GpuWindow.recoverSurface` answers
   `Outdated` (configuring at the window's pixel size, or keeping the surface while a minimized window has no pixels)
   and `Lost` (a new configured surface with the old one's present mode; the old one is released once the new one
   exists), and `GpuWindow.configuredSurfaceFor` creates and configures a surface for a window. The frame loops of the
   window example, `Game.Run` and the native UI host use both and own the surface they end with.
7. **Present modes.** `PresentMode` is `Fifo`, `FifoRelaxed`, `Mailbox` or `Immediate`. A `Surface` carries the mode it
   asks for (`withPresentMode`); `configureSurface` uses it when the surface's capabilities list it and falls back to
   `Fifo`, which every surface supports, and the configured surface's `presentMode` is the mode in use.

## Not in this decision

Index-buffer draws, depth attachments and mipmaps; asynchronous pipeline creation; adapter selection by surface;
`lyric bindgen` support for C unions (`WGPUNativeDisplayHandle`) and function-pointer results (`wgpuGetProcAddress`).
They remain on #8404.
