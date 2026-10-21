# lyric-gpu: vertex and uniform buffers, textures, samplers (docs/67 G5, #7944, D196)

- `Gpu`: `Binding` union and `createRenderBindGroup`, `VertexLayout`/`VertexAttribute` on
  `createRenderPipeline`, `Draw` and `render(.., draws)`, `writeFloats`, `createTexture`,
  `createSampler` and their releases.
- `examples/quad`: textured, tinted quad from a vertex buffer and a uniform buffer, golden image;
  `compute` and `triangle` moved to the new API.
- `native/wgpu_layout_check.c`: `_Static_assert`s for the packed struct sizes, run in
  `scripts/ci/gpu-examples-e2e.sh`.
- Docs: D196, docs/67, CLAUDE.md.
