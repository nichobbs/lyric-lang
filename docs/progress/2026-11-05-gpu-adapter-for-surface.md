# lyric-gpu: adapters chosen for a surface (D373)

docs/67 G5, #8404. `Gpu.SurfaceSource`, `createSurface` and `withDeviceFor(source, body)` open the device on an adapter
that can present to a window (wgpu's `compatibleSurface`), instead of the first adapter. `GpuWindow.sourceFor` and
`withWindowDevice` do it for a `Window.Window` and configure its surface; the window example, `Game.Run` and the native
UI host use them. The window example asks for `Mailbox` and CI checks the mode it got. Asynchronous pipeline creation
is not offered: wgpu-native 29 leaves both async pipeline functions unimplemented (they panic).
