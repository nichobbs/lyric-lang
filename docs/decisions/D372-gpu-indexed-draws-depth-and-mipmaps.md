# D372 - `lyric-gpu`: indexed draws, depth, culling and mipmaps

**Status:** accepted, implemented for `--target native` (docs/67 phase G5, #8404); extends D196 and D371

## Decision

1. **Indexed draws.** `Draw` gains `indices: Option[Indices]`; `Indices` is a buffer (`usageIndex`, written with
   `writeInts`) and a count of 32-bit indices. With indices the draw is `drawIndexed` and `vertexCount` is unused.
   Indices are always 32-bit: 16-bit indices would need a 2-byte write path, and WebGPU's 4-byte write alignment would
   force padding on callers for a saving no current consumer needs. `render` rejects an index count the buffer cannot
   hold before encoding.
2. **A pipeline descriptor.** `RenderPipelineDesc` carries everything a render pipeline is built from, adding
   `depthTest` and `cullBack`; `createRenderPipelineFrom` builds from it, and `createRenderPipeline` keeps its
   signature as the no-depth, no-culling case, so existing callers do not change. A record is used instead of more
   positional parameters because the next options (depth bias, topology, multisampling) extend it without another
   signature change.
3. **Depth.** `createDepthTarget` makes a `Depth32Float` buffer; a `depthTest` pipeline writes depth and passes
   `Less`. `renderWithDepth` clears the depth buffer to 1.0 and rejects a depth target whose size differs from the
   colour target's. Every pipeline in such a pass must have `depthTest`; a mismatch is a wgpu validation error, which
   the call's error scope (D371) returns.
4. **Culling.** `cullBack` culls clockwise triangles (front faces are counter-clockwise, as before).
5. **Mipmaps.** `createMipmappedTexture` creates `mipLevelCount(width, height)` levels and fills each from the one above
   with a 2x2 box filter on the CPU (rounded to nearest; an odd last row or column is folded into its neighbour), and
   `writeTexture` rebuilds the chain for a mipmapped texture. `Texture.mipLevels` records the count. A linear
   `createSampler` now also filters between mip levels (`mipmapFilter = Linear`), which changes nothing for a
   single-level texture. CPU generation was chosen over a GPU blit pass: it is deterministic across Vulkan, Metal and
   D3D12, so one golden image serves all three, and it needs no extra pipeline per texture format.
6. **Test.** `lyric-gpu/examples/layers` draws a near red square before an overlapping far green one, a clockwise blue
   square, and a 64x64 texture of one white column in four on a 16x16 square, and checks at sample pixels that depth
   keeps red in front, the blue square is culled, and the stripes show the mipmap average (64) rather than the
   unmipped sample (0); each check fails when its feature is turned off. It then compares the image with
   `golden/layers-64.rgba`. It runs in `gpu-examples-e2e.sh` (lavapipe), `macos-graphics-e2e.sh` (Metal) and
   `windows-graphics-e2e.sh` (WARP).

## Not in this decision

Stencil, multisampling, depth-only passes and reading depth back; GPU mip generation. Asynchronous pipeline creation,
adapter selection by surface and the bindgen items remain on #8404.
