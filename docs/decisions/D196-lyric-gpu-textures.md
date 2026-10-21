# D196 - `lyric-gpu`: vertex and uniform buffers, textures, samplers and draws

**Status:** accepted, implemented for `--target native` (docs/67 phase G5, #7944); extends D194

## Decision

1. **Bindings.** `createBindGroup` (compute) and `createRenderBindGroup` (render) take a
   `List[Binding]`, where `Binding` is `BufferBinding`, `TextureBinding` or `SamplerBinding`;
   `bindings[i]` is `@binding(i)` of group 0 and the layout is the pipeline's inferred one.
2. **Vertex input.** `createRenderPipeline` takes a `List[VertexLayout]` (stride plus
   `VertexAttribute`s with `vertexFloat32x2` and the other format constants); an empty list is a
   shader that generates its positions. Buffers with `usageVertex`, `usageIndex` or `usageUniform`
   are written with `writeFloats` (32-bit floats), `writeInts` or `writeBytes`.
3. **Draws.** `render(device, target, clear, draws)` runs a `List[Draw]` (pipeline, optional bind
   group, vertex buffers by slot, vertex count) in one pass. This replaces D194's
   single-pipeline `render`.
4. **Textures.** `createTexture` makes an RGBA8 texture from tightly packed `buffer[Byte]` rows
   and writes it with `wgpuQueueWriteTexture`; `createSampler` takes a linear or nearest filter
   and clamps to the edge.
5. **Struct packing.** Arrays of descriptor records (bind group entries, vertex attributes and
   layouts) are built in C memory one record at a time, so their element sizes are spelled out in
   `gpu.l`; `native/wgpu_layout_check.c` compiles them against the headers in CI.
6. **Test.** `examples/quad` draws a 2x2 texture on a quad of two triangles from a vertex buffer,
   tinted by a uniform buffer, and compares the pixels with a golden image on lavapipe.

## Not in this slice

Index-buffer draws, mipmaps, depth and stencil, multisampling, blending, render-to-texture
sampling in the same frame, and surfaces and presentation (need a window system, #8404).
