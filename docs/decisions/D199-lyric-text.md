# D199 - `lyric-text`: shaping, rasterising and layout on FreeType and HarfBuzz

**Status:** accepted, implemented for `--target native` (docs/67 phase G6, #7945); the `Std.Linalg` half of G6 is D198

## Decision

1. **Packages.** `Text.Kernel.Freetype` and `Text.Kernel.Harfbuzz` are `lyric bindgen` output (one
   `--library` each, so each function links its own library) and `Text` is the safe layer, in
   `lyric-text/`. Both libraries are found with pkg-config (`freetype2`, `harfbuzz`).
2. **Structs read by offset.** `FT_GlyphSlotRec`, `FT_SizeRec` and HarfBuzz's glyph info and
   position arrays are read with `nativeLoadByte` at fixed offsets, not bound as records:
   `FT_Outline` and `hb_var_int_t` have shapes `lyric bindgen` rejects, and the only fields needed
   are the bitmap, the bearings and a handful of metrics. `native/text_layout_check.c` asserts
   every offset against the installed headers (LP64 only) and runs in CI.
3. **Surface.** Every native object is an opaque `Long` in a record. `openFont` copies the font
   bytes into C memory (FreeType keeps reading them) and sets one pixel size; a fallback chain is a
   `List[Font]`. `shape` returns a run in visual order with metrics in pixels; `rasterize` returns an
   8-bit coverage bitmap; `Atlas` is a CPU-side shelf packer with a one-pixel gutter and a `version`
   a renderer compares to know when to re-upload; `layoutText` places glyphs in a column.
4. **Layout.** A greedy line breaker over simplified break opportunities (after spaces and hyphens,
   between ideographs, kana and Hangul, with closing punctuation never starting a line and opening
   punctuation never ending one). For each character the first font of the chain with a glyph is
   used; spaces, joiners and combining marks take the previous character's font. A paragraph has
   one base direction from its first strong character, and a right-to-left paragraph lays its words
   out right to left, right-aligned to the column. Text mixing directions inside a paragraph is not
   reordered, and UAX #14 is approximated: both are tracked in #8410 (FriBidi).
5. **Test.** `lyric-text/examples/shape` checks kerning (`AV`), Arabic joining and visual order,
   rasterising, atlas packing, CJK fallback, wrapping and right-to-left alignment, and compares a
   rendered Latin/Arabic/CJK scene with a checked-in golden image within a differing-pixel
   tolerance. `scripts/ci/text-examples-e2e.sh` also runs `lyric bindgen --check` for both kernels.

## Not in this slice

Mixed-direction reordering and full UAX #14 (#8410), glyph subpixel positioning and signed-distance
glyphs (the atlas stores coverage; `lyric-draw` decides how to sample it), colour fonts (a
non-8-bit strike is an `Err` from `rasterize`), variable-font axes, and a macOS CI lane.
