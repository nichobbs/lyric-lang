# `lyric-text`: shaping, rasterising and layout on FreeType and HarfBuzz (docs/67 G6, #7945, D199)

- `lyric-text/`: `Text.Kernel.Freetype` and `Text.Kernel.Harfbuzz` (bindgen output), `Text` (fonts,
  shaping, rasterising, glyph atlas, fallback chains, line layout with right-to-left paragraphs).
- `native/text_layout_check.c` pins every struct offset the safe layer reads.
- `examples/shape`: checks plus a golden Latin/Arabic/CJK scene; `scripts/ci/text-examples-e2e.sh`
  (also `lyric bindgen --check`), wired into `native-backend-self-tests.sh`.
- Docs: D199, docs/67, book chapter 13, CLAUDE.md. Follow-up: #8410 (FriBidi, UAX #14).
