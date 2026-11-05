# lyric-gpu: error scopes, device loss, frame errors and present modes (D374)

docs/67 G5, #8404. Every fallible `Gpu` call runs inside wgpu's validation and out-of-memory error scopes and returns
the error it caused as its own `Err`; `createBuffer`, `createRenderTarget`, `createSampler` and the buffer writes now
return `Result`, and the writes check offset, size and alignment first. A WGSL error is an `Err` starting `WGSL:` with
the compiler's line and column. The device-lost callback is recorded and returned by `deviceLost` and by every later
call. `withDevice` releases the instance, adapter and error cell on each early `Err`. `tryAcquireFrame` returns a
`FrameError` (`Outdated`, `Lost`, `Failed`) and `acquireFrame` is gone; `GpuWindow.recoverSurface` and
`configuredSurfaceFor` serve the frame loops of the window example, `Game.Run` and the native UI host. Surfaces take a
`PresentMode` (`withPresentMode`), falling back to `Fifo`. The compute example now checks that an invalid buffer and
an overrunning write are rejected and leave no error behind. wgpu-native has no internal-error scope (it panics on the
filter), so internal errors still reach `takeError`.
