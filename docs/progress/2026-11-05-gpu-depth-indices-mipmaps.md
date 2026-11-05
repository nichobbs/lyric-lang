# lyric-gpu: indexed draws, depth, culling and mipmaps (D372)

docs/67 G5, #8404. `Draw.indices` draws through a 32-bit index buffer; `RenderPipelineDesc` and
`createRenderPipelineFrom` add `depthTest` and `cullBack`; `createDepthTarget` and `renderWithDepth` render with a
`Depth32Float` buffer; `createMipmappedTexture` builds a full mip chain with a CPU box filter and linear samplers blend
between levels. The new `examples/layers` checks depth, culling, indexed draws and mipmaps at sample pixels (each
check fails with its feature off) and against a golden image, on lavapipe, Metal and WARP.
