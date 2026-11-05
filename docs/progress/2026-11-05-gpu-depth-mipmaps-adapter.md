# lyric-gpu: indexed draws, depth, culling, mipmaps, and adapters chosen for a surface (D375)

docs/67 G5, #8404. `Draw.indices` draws through a 32-bit index buffer; `RenderPipelineDesc` and
`createRenderPipelineFrom` add `depthTest` and `cullBack`; `createDepthTarget` and `renderWithDepth` render with a
`Depth32Float` buffer; `createMipmappedTexture` builds a full mip chain with a CPU box filter and linear samplers blend
between levels. The new `examples/layers` checks depth, culling, indexed draws and mipmaps at sample pixels (each
check fails with its feature off) and against a golden image, on lavapipe, Metal and WARP.

`Gpu.SurfaceSource`, `createSurface` and `withDeviceFor(source, body)` open the device on an adapter
that can present to a window (wgpu's `compatibleSurface`), instead of the first adapter. `GpuWindow.sourceFor` and
`withWindowDevice` do it for a `Window.Window` and configure its surface; the window example, `Game.Run` and the native
UI host use them. The window example asks for `Mailbox` and CI checks the mode it got. Asynchronous pipeline creation
is not offered: wgpu-native 29 leaves both async pipeline functions unimplemented (they panic).
