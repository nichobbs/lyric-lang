# `lyric-draw`: an immediate-mode 2D renderer (docs/67 G6, #7945, D200)

- `lyric-draw/`: `Painter` with filled, stroked and rounded rectangles, soft shadows, images, clip
  stack and text from `lyric-text`, drawn as instanced signed-distance quads in one pipeline.
- `lyric-gpu`: `Draw.instanceCount` / `firstInstance` / `scissor`, a `blend` parameter on
  `createRenderPipeline`, and `writeTexture`; the triangle, quad and window examples are updated.
- `examples/scene`: golden scene plus `--stress`; `scripts/ci/draw-examples-e2e.sh`, wired into
  `native-backend-self-tests.sh`.
- Docs: D200, docs/67, book chapter 13, CLAUDE.md.
