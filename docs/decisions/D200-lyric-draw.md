# D200 - `lyric-draw`: an immediate-mode 2D renderer, and the `lyric-gpu` changes it needs

**Status:** accepted, implemented for `--target native` (docs/67 phase G6, #7945); extends D194 to D197, builds on D199 (`lyric-text`)

## Decision

1. **Model.** A `Painter` collects one frame as instances of a single pipeline, in drawing order,
   and `finish` submits it. Primitives are filled, stroked and rounded rectangles, soft shadows,
   images and text; each is one instance drawn as a quad whose fragment shader evaluates a signed
   distance (rounded boxes: the usual `length(max(q, 0)) + min(max(q.x, q.y), 0) - r`) with a one
   pixel antialiased edge, a shadow's blur widening its quad. Text draws glyph quads sampling the
   `lyric-text` atlas, held in an RGBA8 texture premultiplied in all four channels so a glyph's
   tint times the sample is the tint times its coverage. Colours are straight RGBA in the API and
   composited premultiplied.
2. **One pipeline, instances in a storage buffer.** The vertex shader reads instance
   `@builtin(instance_index)` from a read-only storage buffer and generates six corner vertices;
   there are no vertex buffers. Consecutive instances sharing a texture and a clip rectangle form
   one batch and one instanced draw. The instance buffer doubles when a frame outgrows it.
3. **Clipping** is a stack of rectangles rounded outward to whole pixels; the effective clip is the
   intersection, applied as a scissor, and a fully clipped instance is dropped.
4. **`lyric-gpu` changes** (all additive except two signatures, whose in-repo callers are updated):
   `Draw` gains `instanceCount`, `firstInstance` and `scissor: Option[Scissor]`;
   `createRenderPipeline` takes a `blend: Bool` (premultiplied alpha "over"); `writeTexture`
   replaces a texture's pixels, so a changing atlas is re-uploaded in place.
5. **Test.** `lyric-draw/examples/scene` draws a card with a shadow, border, rounded shapes, an
   alpha-blended image and wrapped and clipped Latin, Arabic and CJK text offscreen and compares it
   with a golden image (per-channel tolerance 24, differing-pixel budget 600). `scene --stress`
   times a text-heavy 1280x720 frame (about 5,000 glyphs, laid out, packed and drawn): about 20 ms
   on lavapipe locally against a CI ceiling of 100 ms, which is a software-rasteriser ceiling and
   not a 60 fps assertion. `scripts/ci/draw-examples-e2e.sh` runs both.

## Not in this slice

Run on real GPU hardware (the golden image and the frame budget are checked on lavapipe only),
gradients, arbitrary paths and their CPU tessellation, layers and offscreen compositing, signed
distance text for scaling, and rotated or transformed quads. The native `lyric-ui` host (G10) and
`lyric-game` (G7) build on this.
