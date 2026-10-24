/* Compile-time check of the struct offsets and sizes src/text.l reads with nativeLoadByte.
 * Build with: cc -fsyntax-only $(pkg-config --cflags freetype2 harfbuzz) native/text_layout_check.c
 * (and with --target=x86_64-pc-windows-msvc for the Windows offsets). */
#include <stddef.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_SIZES_H
#include <hb.h>

#define CHECK(name, cond) _Static_assert(cond, name)

CHECK("64-bit pointers: the offsets below are the 64-bit ones", sizeof(void *) == 8);

#ifdef _WIN32
/* LLP64: FreeType's FT_Long / FT_Pos fields are 32 bits wide. */
CHECK("LLP64: long is 32 bits", sizeof(long) == 4);
CHECK("FT_FaceRec.glyph at 120", offsetof(FT_FaceRec, glyph) == 120);
CHECK("FT_FaceRec.size at 128", offsetof(FT_FaceRec, size) == 128);
CHECK("FT_FaceRec.units_per_EM at 104", offsetof(FT_FaceRec, units_per_EM) == 104);
CHECK("FT_SizeRec.metrics at 24", offsetof(FT_SizeRec, metrics) == 24);
CHECK("FT_Size_Metrics.ascender at 12", offsetof(FT_Size_Metrics, ascender) == 12);
CHECK("FT_Size_Metrics.descender at 16", offsetof(FT_Size_Metrics, descender) == 16);
CHECK("FT_Size_Metrics.height at 20", offsetof(FT_Size_Metrics, height) == 20);
CHECK("FT_GlyphSlotRec.advance at 88", offsetof(FT_GlyphSlotRec, advance) == 88);
CHECK("FT_GlyphSlotRec.bitmap at 104", offsetof(FT_GlyphSlotRec, bitmap) == 104);
CHECK("FT_GlyphSlotRec.bitmap_left at 144", offsetof(FT_GlyphSlotRec, bitmap_left) == 144);
CHECK("FT_GlyphSlotRec.bitmap_top at 148", offsetof(FT_GlyphSlotRec, bitmap_top) == 148);
#else
/* LP64 (Linux, macOS). */
CHECK("LP64: long is 64 bits", sizeof(long) == 8);
CHECK("FT_FaceRec.glyph at 152", offsetof(FT_FaceRec, glyph) == 152);
CHECK("FT_FaceRec.size at 160", offsetof(FT_FaceRec, size) == 160);
CHECK("FT_FaceRec.units_per_EM at 136", offsetof(FT_FaceRec, units_per_EM) == 136);
CHECK("FT_SizeRec.metrics at 24", offsetof(FT_SizeRec, metrics) == 24);
CHECK("FT_Size_Metrics.ascender at 24", offsetof(FT_Size_Metrics, ascender) == 24);
CHECK("FT_Size_Metrics.descender at 32", offsetof(FT_Size_Metrics, descender) == 32);
CHECK("FT_Size_Metrics.height at 40", offsetof(FT_Size_Metrics, height) == 40);
CHECK("FT_GlyphSlotRec.advance at 128", offsetof(FT_GlyphSlotRec, advance) == 128);
CHECK("FT_GlyphSlotRec.bitmap at 152", offsetof(FT_GlyphSlotRec, bitmap) == 152);
CHECK("FT_GlyphSlotRec.bitmap_left at 192", offsetof(FT_GlyphSlotRec, bitmap_left) == 192);
CHECK("FT_GlyphSlotRec.bitmap_top at 196", offsetof(FT_GlyphSlotRec, bitmap_top) == 196);
#endif
CHECK("FT_Bitmap.rows at 0", offsetof(FT_Bitmap, rows) == 0);
CHECK("FT_Bitmap.width at 4", offsetof(FT_Bitmap, width) == 4);
CHECK("FT_Bitmap.pitch at 8", offsetof(FT_Bitmap, pitch) == 8);
CHECK("FT_Bitmap.buffer at 16", offsetof(FT_Bitmap, buffer) == 16);
CHECK("FT_Bitmap.pixel_mode at 26", offsetof(FT_Bitmap, pixel_mode) == 26);
CHECK("hb_glyph_info_t is 20 bytes", sizeof(hb_glyph_info_t) == 20);
CHECK("hb_glyph_info_t.cluster at 8", offsetof(hb_glyph_info_t, cluster) == 8);
CHECK("hb_glyph_position_t is 20 bytes", sizeof(hb_glyph_position_t) == 20);
CHECK("hb_glyph_position_t.x_offset at 8", offsetof(hb_glyph_position_t, x_offset) == 8);
