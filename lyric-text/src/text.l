//! text.l - Text: font loading, shaping, glyph rasterisation and line layout for
//! `--target native`, over FreeType and HarfBuzz (docs/67 phase G6).
//!
//! Every native object is an opaque `Long` handle inside a record, so no `NativePtr` crosses this
//! package's public surface.  A `Font` is one face at one pixel size; a fallback chain is a
//! `List[Font]` and `layoutText` picks, for each character, the first font in the chain that has
//! a glyph for it.
//!
//! Shaping is HarfBuzz's: ligatures, kerning, Arabic joining and Indic reordering come from the
//! font's own tables.  Layout is a greedy line breaker over the line break opportunities of UAX #14,
//! and each paragraph is reordered with the Unicode Bidirectional Algorithm (UAX #9): a Latin word
//! or a number inside Arabic or Hebrew text, and the reverse, keeps its own order, and right to left
//! runs are shaped from their reading order with mirrored brackets.  Both algorithms come from
//! lyric-unicode (`Unicode.Bidi`, `Unicode.LineBreak`, #8496).  `layoutRun` lays out one run in a
//! direction the caller gives, for callers that reorder text themselves (the native lyric-ui host's
//! text areas, which also place a caret and selection in it).
//!
//! Glyphs rasterise to 8-bit coverage bitmaps and pack into a CPU-side `Atlas` that a renderer
//! uploads as an R8 texture.
@io
package Text

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Ffi as Ffi
import Text.Kernel.Freetype as Ft
import Text.Kernel.Harfbuzz as Hb
import Unicode.Bidi
import Unicode.LineBreak
import Unicode.Data as UnicodeData

// FT_LOAD_NO_HINTING: advances and outlines at the exact scale, so shaping and rasterising agree.
val dirGuess: Int = 0

val dirLtr: Int = 4

val dirRtl: Int = 5

val loadNoHinting: Int = 2

val loadRender: Int = 4

/// The FreeType library.  One per program is enough; fonts opened from it must be closed first.
pub record TextLib {
  raw: Long
}

/// One face at one pixel size.  `ascent`, `descent` and `lineHeight` are in pixels.
pub record Font {
  id: Int
  face: Long
  hb: Long
  data: Long
  pixelSize: Int
  ascent: Float
  descent: Float
  lineHeight: Float
}

/// One shaped glyph in visual order: `glyph` is the font's glyph index, `cluster` the byte offset
/// of its first character in the UTF-8 text, and the metrics are in pixels.
pub record ShapedGlyph {
  glyph: Int
  cluster: Int
  xAdvance: Float
  yAdvance: Float
  xOffset: Float
  yOffset: Float
}

/// A glyph's coverage bitmap: `width` by `height` bytes, row-major with no padding.  `left` and
/// `top` place its top-left corner relative to the pen position on the baseline (`top` is
/// upward from the baseline).  A glyph with no ink (a space) has a zero `width` and `height`.
pub record GlyphBitmap {
  width: Int
  height: Int
  left: Int
  top: Int
  pixels: buffer[Byte]
}

/// A glyph positioned by `layoutText`: `font` indexes the chain given to it, `x` is the pen
/// position plus the glyph's offset, and `y` is the baseline of its line, both in pixels from
/// the layout's top-left corner with y growing downward.
pub record PlacedGlyph {
  font: Int
  glyph: Int
  x: Float
  y: Float
  line: Int
}

/// A laid-out block of text.
pub record TextLayout {
  glyphs: List[PlacedGlyph]
  lineCount: Int
  width: Float
  height: Float
}

extern func memcpyToLong(dst: NativePtr[Long], src: NativePtr[NativePtr[Byte]], n: Long): NativePtr[Byte] = "memcpy"

extern func memcpyToPtr(dst: NativePtr[NativePtr[Byte]], src: NativePtr[Long], n: Long): NativePtr[Byte] = "memcpy"

@unsafe_ffi
func ptrToLong(p: NativePtr[Byte]): Long {
  var src = p
  var dst: Long = 0
  val _ = memcpyToLong(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func longToPtr(v: Long): NativePtr[Byte] {
  var src = v
  var dst: NativePtr[Byte] = nativeNullPtr()
  val _ = memcpyToPtr(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func loadByteAt(p: NativePtr[Byte], offset: Long): Long {
  nativeLoadByte(p, offset).toLong()
}

@unsafe_ffi
func loadInt32(p: NativePtr[Byte], offset: Long): Int {
  val v = loadByteAt(p, offset) + loadByteAt(p, offset + 1) * 256 + loadByteAt(p, offset + 2) * 65536 +
    loadByteAt(p, offset + 3) * 16777216
  if v >= 2147483648 {
    (v - 4294967296).toInt()
  } else {
    v.toInt()
  }
}

@unsafe_ffi
func loadUInt32(p: NativePtr[Byte], offset: Long): Long {
  loadByteAt(p, offset) + loadByteAt(p, offset + 1) * 256 + loadByteAt(p, offset + 2) * 65536 +
    loadByteAt(p, offset + 3) * 16777216
}

// Little-endian, as two halves so a negative value (a descender) does not overflow the product.
@unsafe_ffi
func loadInt64(p: NativePtr[Byte], offset: Long): Long {
  loadInt32(p, offset + 4).toLong() * 4294967296 + loadUInt32(p, offset)
}

// A FreeType `FT_Pos` / `FT_Long` field: a C `long`, 64 bits on LP64 and 32 on Windows.
@cfg(not(target_os = "windows"))
@unsafe_ffi
func loadCLong(p: NativePtr[Byte], offset: Long): Long {
  loadInt64(p, offset)
}

@cfg(target_os = "windows")
@unsafe_ffi
func loadCLong(p: NativePtr[Byte], offset: Long): Long {
  loadInt32(p, offset).toLong()
}

@unsafe_ffi
func loadPointer(p: NativePtr[Byte], offset: Long): NativePtr[Byte] {
  longToPtr(loadInt64(p, offset))
}

// Offsets into FreeType's public structs, checked by native/text_layout_check.c: LP64 (Linux,
// macOS) and LLP64 (Windows, where FreeType's `long` fields are 32 bits wide).
@cfg(not(target_os = "windows"))
val faceGlyphOffset: Long = 152

@cfg(target_os = "windows")
val faceGlyphOffset: Long = 120

@cfg(not(target_os = "windows"))
val faceSizeOffset: Long = 160

@cfg(target_os = "windows")
val faceSizeOffset: Long = 128

@cfg(not(target_os = "windows"))
val sizeMetricsAscender: Long = 48

@cfg(target_os = "windows")
val sizeMetricsAscender: Long = 36

@cfg(not(target_os = "windows"))
val sizeMetricsDescender: Long = 56

@cfg(target_os = "windows")
val sizeMetricsDescender: Long = 40

@cfg(not(target_os = "windows"))
val sizeMetricsHeight: Long = 64

@cfg(target_os = "windows")
val sizeMetricsHeight: Long = 44

@cfg(not(target_os = "windows"))
val slotAdvanceOffset: Long = 128

@cfg(target_os = "windows")
val slotAdvanceOffset: Long = 88

@cfg(not(target_os = "windows"))
val slotBitmapOffset: Long = 152

@cfg(target_os = "windows")
val slotBitmapOffset: Long = 104

@cfg(not(target_os = "windows"))
val slotBitmapLeftOffset: Long = 192

@cfg(target_os = "windows")
val slotBitmapLeftOffset: Long = 144

@cfg(not(target_os = "windows"))
val slotBitmapTopOffset: Long = 196

@cfg(target_os = "windows")
val slotBitmapTopOffset: Long = 148

/// Starts FreeType.
@unsafe_ffi
pub func initText(): Result[TextLib, String] {
  var lib: NativePtr[Byte] = nativeNullPtr()
  val rc = Ft.FT_Init_FreeType(nativeAddrOf(lib))
  if rc != 0 {
    return Err(error = "FreeType: cannot initialise (error " + rc.toString() + ")")
  }
  Ok(value = TextLib(raw = ptrToLong(lib)))
}

@unsafe_ffi
pub func closeText(lib: TextLib): Unit {
  val _ = Ft.FT_Done_FreeType(longToPtr(lib.raw))
}

/// Opens face `faceIndex` of the font file in `bytes` (TrueType, OpenType, a .ttc collection) at
/// `pixelSize` pixels per em.
@unsafe_ffi
pub func openFont(lib: TextLib, id: Int, bytes: slice[Byte], faceIndex: Int, pixelSize: Int): Result[Font, String] {
  if pixelSize <= 0 {
    return Err(error = "openFont: the pixel size must be positive")
  }
  val n = bytes.length
  val data = Ffi.allocate(n.toLong())
  var i = 0
  while i < n {
    nativeStoreByte(data, i.toLong(), bytes[i])
    i = i + 1
  }
  var face: NativePtr[Ft.FT_FaceRec] = nativeNullPtr()
  val rc = Ft.FT_New_Memory_Face(
    longToPtr(lib.raw),
    data,
    Ft.toCLong(n.toLong()),
    Ft.toCLong(faceIndex.toLong()),
    nativeAddrOf(face)
  )
  if rc != 0 {
    Ffi.release(data)
    return Err(error = "FreeType: cannot read the font (error " + rc.toString() + ")")
  }
  val faceRaw = ptrToLong(face)
  val sc = Ft.FT_Set_Pixel_Sizes(face, 0, pixelSize)
  if sc != 0 {
    val _ = Ft.FT_Done_Face(face)
    Ffi.release(data)
    return Err(error = "FreeType: cannot set the pixel size (error " + sc.toString() + ")")
  }
  val hbFont = Hb.hb_ft_font_create_referenced(longToPtr(faceRaw))
  Hb.hb_ft_font_set_load_flags(hbFont, loadNoHinting)
  val metrics = loadPointer(longToPtr(faceRaw), faceSizeOffset)
  val ascender = loadCLong(metrics, sizeMetricsAscender)
  val descender = loadCLong(metrics, sizeMetricsDescender)
  val height = loadCLong(metrics, sizeMetricsHeight)
  Ok(
    value = Font(
      id = id,
      face = faceRaw,
      hb = ptrToLong(hbFont),
      data = ptrToLong(data),
      pixelSize = pixelSize,
      ascent = ascender.toFloat() / 64.0f32,
      descent = (0 - descender).toFloat() / 64.0f32,
      lineHeight = height.toFloat() / 64.0f32
    )
  )
}

/// Releases a font.  Shaped glyph runs and bitmaps already returned stay valid.
@unsafe_ffi
pub func closeFont(f: Font): Unit {
  Hb.hb_font_destroy(longToPtr(f.hb))
  val _ = Ft.FT_Done_Face(longToPtr(f.face))
  Ffi.release(longToPtr(f.data))
}

/// Whether the font has a glyph for the Unicode scalar value `codepoint`.
@unsafe_ffi
pub func hasGlyph(f: Font, codepoint: Int): Bool {
  Ft.FT_Get_Char_Index(longToPtr(f.face), Ft.toCLong(codepoint.toLong())) != 0
}

// ---------------------------------------------------------------------------
// UTF-8 text in C memory.
// ---------------------------------------------------------------------------
/// A NUL-terminated UTF-8 copy of a string and its length in bytes.
record Utf8 {
  ptr: Long
  length: Int
}

@unsafe_ffi
func utf8Of(s: String): Utf8 {
  val p = Ffi.toCString(s)
  var n = 0
  while nativeLoadByte(p, n.toLong()) != 0u8 {
    n = n + 1
  }
  Utf8(ptr = ptrToLong(p), length = n)
}

@unsafe_ffi
func utf8Free(u: Utf8): Unit {
  Ffi.release(longToPtr(u.ptr))
}

/// The byte length of the UTF-8 sequence that starts with `lead`.
func sequenceLength(lead: Int): Int {
  if lead < 128 {
    1
  } else if lead >= 240 {
    4
  } else if lead >= 224 {
    3
  } else if lead >= 192 {
    2
  } else {
    1
  }
}

/// The scalar value starting at byte `i` of `u`.
@unsafe_ffi
func codepointAt(u: Utf8, i: Int): Int {
  val p = longToPtr(u.ptr)
  val lead = nativeLoadByte(p, i.toLong()).toInt()
  val len = sequenceLength(lead)
  if len == 1 {
    return lead
  }
  var cp = if len == 2 { lead - 192 } else if len == 3 { lead - 224 } else { lead - 240 }
  var k = 1
  while k < len and i + k < u.length {
    cp = cp * 64 + (nativeLoadByte(p, (i + k).toLong()).toInt() - 128)
    k = k + 1
  }
  cp
}

// ---------------------------------------------------------------------------
// Shaping.
// ---------------------------------------------------------------------------
/// Shapes the byte range `[start, stop)` of `u` with `f`, with the rest of the text as context.
/// Script and language are guessed from the range's characters, and so is the direction unless
/// `dir` is `dirLtr` or `dirRtl` (HarfBuzz's own numbers): a right to left buffer is shaped from the
/// text in reading order, its glyphs come back left to right, and its mirrored characters are swapped.
@unsafe_ffi
func shapeRange(f: Font, u: Utf8, start: Int, stop: Int, dir: Int): List[ShapedGlyph] {
  val buf = Hb.hb_buffer_create()
  Hb.hb_buffer_add_utf8(buf, longToPtr(u.ptr), u.length, start, stop - start)
  if dir != dirGuess {
    Hb.hb_buffer_set_direction(buf, dir)
  }
  Hb.hb_buffer_guess_segment_properties(buf)
  Hb.hb_shape(longToPtr(f.hb), buf, nativeNullPtr(), 0)
  val count = Hb.hb_buffer_get_length(buf)
  val infos: NativePtr[Byte] = Hb.hb_buffer_get_glyph_infos(buf, nativeNullPtr())
  val positions: NativePtr[Byte] = Hb.hb_buffer_get_glyph_positions(buf, nativeNullPtr())
  val placed: List[ShapedGlyph] = newList()
  var i = 0
  while i < count {
    val base = (i * 20).toLong()
    placed.add(
      ShapedGlyph(
        glyph = loadInt32(infos, base),
        cluster = loadInt32(infos, base + 8),
        xAdvance = loadInt32(positions, base).toFloat() / 64.0f32,
        yAdvance = loadInt32(positions, base + 4).toFloat() / 64.0f32,
        xOffset = loadInt32(positions, base + 8).toFloat() / 64.0f32,
        yOffset = loadInt32(positions, base + 12).toFloat() / 64.0f32
      )
    )
    i = i + 1
  }
  Hb.hb_buffer_destroy(buf)
  placed
}

/// Shapes `text` with one font as a single run.  Glyphs come back in visual order, left to
/// right on screen, whatever the text's direction.
@unsafe_ffi
pub func shape(f: Font, text: String): List[ShapedGlyph] {
  val u = utf8Of(text)
  val glyphs = shapeRange(f, u, 0, u.length, dirGuess)
  utf8Free(u)
  glyphs
}

/// The width of a shaped run in pixels.
pub func runWidth(glyphs: List[ShapedGlyph]): Float {
  var w = 0.0f32
  for g in glyphs {
    w = w + g.xAdvance
  }
  w
}

// ---------------------------------------------------------------------------
// Rasterising.
// ---------------------------------------------------------------------------
/// Renders glyph `glyph` of `f` to an 8-bit coverage bitmap.
@unsafe_ffi
pub func rasterize(f: Font, glyph: Int): Result[GlyphBitmap, String] {
  val face = longToPtr(f.face)
  val rc = Ft.FT_Load_Glyph(face, glyph, loadNoHinting + loadRender)
  if rc != 0 {
    return Err(error = "FreeType: cannot render glyph " + glyph.toString() + " (error " + rc.toString() + ")")
  }
  val slot = loadPointer(face, faceGlyphOffset)
  if nativeLoadByte(slot, slotBitmapOffset + 26) != 2u8 and loadInt32(slot, slotBitmapOffset) != 0 {
    return Err(
      error = "rasterize: glyph " + glyph.toString() +
        " is not an 8-bit coverage bitmap (a colour or monochrome strike)"
    )
  }
  val rows = loadInt32(slot, slotBitmapOffset)
  val width = loadInt32(slot, slotBitmapOffset + 4)
  val pitch = loadInt32(slot, slotBitmapOffset + 8)
  val data = loadPointer(slot, slotBitmapOffset + 16)
  val left = loadInt32(slot, slotBitmapLeftOffset)
  val top = loadInt32(slot, slotBitmapTopOffset)
  if rows == 0 or width == 0 {
    return Ok(value = GlyphBitmap(width = 0, height = 0, left = left, top = top, pixels = Buf.filled(0, 0u8)))
  }
  var pixels = Buf.filled(rows * width, 0u8)
  var y = 0
  while y < rows {
    var x = 0
    while x < width {
      pixels[y * width + x] = nativeLoadByte(data, (y * pitch + x).toLong())
      x = x + 1
    }
    y = y + 1
  }
  Ok(value = GlyphBitmap(width = width, height = rows, left = left, top = top, pixels = pixels))
}

// ---------------------------------------------------------------------------
// Glyph atlas.
// ---------------------------------------------------------------------------
/// Where a glyph lives in an `Atlas`, and how to place it: `left` and `top` are the glyph's
/// offsets from the pen position on the baseline, as in `GlyphBitmap`.
pub record AtlasRegion {
  x: Int
  y: Int
  width: Int
  height: Int
  left: Int
  top: Int
}

/// A CPU-side glyph atlas: an R8 image that rows of glyph bitmaps are packed into, one pixel
/// apart so a linearly filtered sample never reads a neighbour.  Upload `pixels` as an R8
/// texture whenever `version` has changed since the last upload.
pub ref record Atlas {
  width: Int
  height: Int
  var pixels: buffer[Byte]
  var penX: Int
  var penY: Int
  var rowHeight: Int
  var version: Int
  var regions: Map[Long, AtlasRegion]
}

pub func newAtlas(width: Int, height: Int): Atlas
  requires: width > 0 and height > 0
{
  Atlas(
    width = width,
    height = height,
    pixels = Buf.filled(width * height, 0u8),
    penX = 0,
    penY = 0,
    rowHeight = 0,
    version = 0,
    regions = newMap()
  )
}

func atlasKey(f: Font, glyph: Int): Long {
  f.id.toLong() * 4294967296 + glyph.toLong()
}

/// The atlas region of glyph `glyph` of `f`, rasterising and packing it first when it is new.
/// `Err` when the atlas has no room left (make a larger one, or one per size).
pub func atlasGlyph(a: Atlas, f: Font, glyph: Int): Result[AtlasRegion, String] {
  val key = atlasKey(f, glyph)
  match mapGet(a.regions, key) {
    case Some(r) -> return Ok(value = r)
    case None -> ()
  }
  val bmp = match rasterize(f, glyph) { case Ok(b) -> b; case Err(e) -> return Err(error = e) }
  if bmp.width == 0 {
    val empty = AtlasRegion(x = 0, y = 0, width = 0, height = 0, left = bmp.left, top = bmp.top)
    a.regions.add(key, empty)
    return Ok(value = empty)
  }
  if bmp.width > a.width or bmp.height > a.height {
    return Err(error = "atlas: glyph " + glyph.toString() + " is larger than the atlas")
  }
  // Decide the shelf before touching the atlas, so a glyph that does not fit leaves it as it was.
  var px = a.penX
  var py = a.penY
  var rowH = a.rowHeight
  if px + bmp.width > a.width {
    px = 0
    py = py + rowH + 1
    rowH = 0
  }
  if py + bmp.height > a.height {
    return Err(error = "atlas: out of room for glyph " + glyph.toString())
  }
  var row = 0
  while row < bmp.height {
    var col = 0
    while col < bmp.width {
      a.pixels[(py + row) * a.width + px + col] = bmp.pixels[row * bmp.width + col]
      col = col + 1
    }
    row = row + 1
  }
  val region = AtlasRegion(x = px, y = py, width = bmp.width, height = bmp.height, left = bmp.left, top = bmp.top)
  a.penX = px + bmp.width + 1
  a.penY = py
  a.rowHeight = if bmp.height > rowH { bmp.height } else { rowH }
  a.version = a.version + 1
  a.regions.add(key, region)
  Ok(value = region)
}

// ---------------------------------------------------------------------------
// Line layout.
// ---------------------------------------------------------------------------
func isSpaceCp(cp: Int): Bool {
  cp == 32 or cp == 9
}

// A character that takes the font of the one before it: spaces, joiners, combining marks.  The marks
// are those Unicode.Data flags Mn/Mc or gives the CM and ZWJ line-break classes, so Hebrew points,
// Indic vowel signs and the like stay in their base's run instead of shaping alone on a dotted circle.
func isNeutralCp(cp: Int): Bool {
  if cp <= 32 or cp == 160 or (cp >= 65024 and cp <= 65039) {
    return true
  }
  val v = UnicodeData.lineBreakValueOf(cp)
  val cls = v.and(63)
  v.and(1024) != 0 or cls == 9 or cls == 42 or cls == 12 or cls == 30 or cls == 28
}

// The characters rule L1 of UAX #9 may give the paragraph's level at the end of a line or before a
// tab: whitespace, separators, isolate controls, and those rule X9 removes.  Shaped runs never mix
// them with other characters, so every run of a line has one level.
func resetByL1(cls: Int): Bool {
  cls == 7 or cls == 8 or cls == 9 or (cls >= 19 and cls <= 22) or cls == 11 or cls == 12 or cls == 14 or cls == 15 or
    cls == 16 or
    cls == 18
}

@unsafe_ffi
func scalarEnd(u: Utf8, i: Int): Int {
  val e = i + sequenceLength(nativeLoadByte(longToPtr(u.ptr), i.toLong()).toInt())
  if e > u.length {
    u.length
  } else {
    e
  }
}

// One paragraph as code points: `cps[k]` starts at byte `bytes[k]` of the text, and `bytes[n]` is the
// paragraph's end.  `levels` are the embedding levels of UAX #9 (all `paraLevel` when nothing in the
// paragraph can reorder, `reorders` false), and `l1` marks the characters rule L1 may reset.
record Paragraph {
  cps: slice[Int]
  bytes: List[Int]
  levels: List[Int]
  l1: List[Bool]
  paraLevel: Int
  reorders: Bool
}

func paragraphOf(u: Utf8, start: Int, stop: Int, dir: Int): Paragraph {
  val cpList: List[Int] = newList()
  val bytes: List[Int] = newList()
  var i = start
  while i < stop {
    bytes.add(i)
    cpList.add(codepointAt(u, i))
    i = scalarEnd(u, i)
  }
  bytes.add(stop)
  val cps = cpList.toArray()
  val n = cps.length
  val reorders = dir == dirGuess and Bidi.needsBidi(cps, 0, n)
  val paraLevel = if dir == dirRtl {
    1
  } else if dir == dirLtr {
    0
  } else if reorders {
    Bidi.paragraphLevelOf(cps, 0, n)
  } else {
    0
  }
  val l1: List[Bool] = newList()
  var levels: List[Int] = newList()
  if reorders {
    levels = Bidi.resolveLevels(cps, 0, n, paraLevel)
    for cp in cps {
      l1.add(resetByL1(UnicodeData.bidiClassOf(cp)))
    }
  } else {
    var k = 0
    while k < n {
      levels.add(paraLevel)
      l1.add(false)
      k = k + 1
    }
  }
  Paragraph(cps = cps, bytes = bytes, levels = levels, l1 = l1, paraLevel = paraLevel, reorders = reorders)
}

// A stretch `from ..< to` of a paragraph's code points shaped with one font in one direction.
record Run {
  font: Int
  glyphs: List[ShapedGlyph]
  width: Float
  from: Int
  to: Int
  level: Int
}

// A word (the text up to the next line break opportunity, without its trailing spaces) or the
// spaces after one.  `forced` is a required break before it inside the paragraph.
record Seg {
  runs: List[Run]
  width: Float
  isSpace: Bool
  from: Int
  to: Int
  forced: Bool
}

func fontFor(fonts: List[Font], cp: Int): Int {
  var k = 0
  while k < fonts.count {
    if hasGlyph(fonts[k], cp) {
      return k
    }
    k = k + 1
  }
  0
}

func directionOf(level: Int): Int {
  if level % 2 == 1 {
    dirRtl
  } else {
    dirLtr
  }
}

// Shapes the code points `from ..< to` of the paragraph as one segment, in runs that change where
// the chain's font, the embedding level or rule L1's class does.
func shapeSegment(fonts: List[Font], u: Utf8, p: Paragraph, from: Int, to: Int, isSpace: Bool, forced: Bool): Seg {
  val runs: List[Run] = newList()
  var runStart = from
  var runFont = -1
  var i = from
  while i < to {
    val cp = p.cps[i]
    val f = if isNeutralCp(cp) and runFont >= 0 { runFont } else { fontFor(fonts, cp) }
    if runFont >= 0 and (f != runFont or p.levels[i] != p.levels[runStart] or p.l1[i] != p.l1[runStart]) {
      runs.add(shapeRun(fonts, u, p, runFont, runStart, i))
      runStart = i
    }
    runFont = f
    i = i + 1
  }
  if runFont < 0 {
    runFont = 0
  }
  if to > runStart {
    runs.add(shapeRun(fonts, u, p, runFont, runStart, to))
  }
  var w = 0.0f32
  for r in runs {
    w = w + r.width
  }
  Seg(runs = runs, width = w, isSpace = isSpace, from = from, to = to, forced = forced)
}

func shapeRun(fonts: List[Font], u: Utf8, p: Paragraph, font: Int, from: Int, to: Int): Run {
  val level = p.levels[from]
  val g = shapeRange(fonts[font], u, p.bytes[from], p.bytes[to], directionOf(level))
  Run(font = font, glyphs = g, width = runWidth(g), from = from, to = to, level = level)
}

// Cuts a paragraph at the line break opportunities of UAX #14 into words and the spaces after them,
// shaped.  Required breaks inside the paragraph (a line separator) are kept only when `wrapForced`.
func segmentParagraph(fonts: List[Font], u: Utf8, p: Paragraph, wrapForced: Bool): List[Seg] {
  val segs: List[Seg] = newList()
  val n = p.cps.length
  if n == 0 {
    return segs
  }
  val breaks = LineBreak.breaksIn(p.cps, 0, n)
  var s = 0
  while s < n {
    var e = s + 1
    while e < n and breaks[e] == LineBreak.noBreak {
      e = e + 1
    }
    var w = e
    while w > s and isSpaceCp(p.cps[w - 1]) {
      w = w - 1
    }
    val forced = wrapForced and s > 0 and breaks[s] == LineBreak.breakRequired
    if w > s {
      segs.add(shapeSegment(fonts, u, p, s, w, false, forced))
    }
    if e > w {
      segs.add(shapeSegment(fonts, u, p, w, e, true, forced and w == s))
    }
    s = e
  }
  segs
}

func placeRun(placed: List[PlacedGlyph], run: Run, startX: Float, baseline: Float, lineIndex: Int): Float {
  var x = startX
  for g in run.glyphs {
    placed.add(
      PlacedGlyph(font = run.font, glyph = g.glyph, x = x + g.xOffset, y = baseline - g.yOffset, line = lineIndex)
    )
    x = x + g.xAdvance
  }
  x
}

// Places one line (its segments in logical order, `lineWidth` wide): its runs in the visual order of
// UAX #9 (rules L1 and L2), a run's glyphs in the order HarfBuzz gives them, and a right to left
// paragraph against the right edge of the column.
func placeLine(
  placed: List[PlacedGlyph],
  line: List[Seg],
  lineWidth: Float,
  maxWidth: Float,
  baseline: Float,
  lineIndex: Int,
  p: Paragraph,
): Unit {
  if line.count == 0 {
    return
  }
  val runs: List[Run] = newList()
  for seg in line {
    for r in seg.runs {
      runs.add(r)
    }
  }
  val lineFrom = line[0].from
  val lineTo = line[line.count - 1].to
  val visual = if p.reorders {
    Bidi.lineRuns(p.cps, 0, p.levels, lineFrom, lineTo, p.paraLevel)
  } else {
    val one: List[Bidi.BidiRun] = newList()
    one.add(Bidi.BidiRun(from = lineFrom, to = lineTo, level = p.paraLevel))
    one
  }
  var x = if p.paraLevel == 1 and maxWidth > 0.0f32 { maxWidth - lineWidth } else { 0.0f32 }
  for v in visual {
    val rtl = v.level % 2 == 1
    var k = 0
    while k < runs.count {
      val r = if rtl { runs[runs.count - 1 - k] } else { runs[k] }
      if r.from >= v.from and r.to <= v.to {
        x = placeRun(placed, r, x, baseline, lineIndex)
      }
      k = k + 1
    }
  }
}

/// Lays `text` out in a column `maxWidth` pixels wide (no wrapping when it is not positive).  Lines
/// break at `\n`, at the other required breaks of UAX #14 (a line separator), and, to fit the column,
/// at the line break opportunities of UAX #14 (after spaces and hyphens, between ideographs, the
/// kinsoku and number rules); spaces at the start and end of a line are not placed.  Each paragraph is
/// reordered by the Unicode Bidirectional Algorithm: its direction is that of its first strong
/// character, each line's runs are placed in visual order, a right to left run is shaped from its
/// reading order with its brackets mirrored, and a right to left paragraph is aligned to the right
/// of the column.  `fonts` is the fallback chain, its first font setting the line height.
@unsafe_ffi
pub func layoutText(fonts: List[Font], text: String, maxWidth: Float): TextLayout
  requires: fonts.count > 0
{
  layoutDirected(fonts, text, maxWidth, dirGuess)
}

/// Lays `text` out on one line in the direction `rtl` says, whatever its characters are: a run of
/// text that is all in one direction, as the Unicode Bidirectional Algorithm gives it.  Right to left
/// text is shaped from its reading order, so Arabic letters join, its words are placed right to
/// left, and its brackets and other mirrored characters are swapped, even when the run holds only
/// neutral characters; left to right text keeps its order even when it holds Hebrew or Arabic.
/// `text` has no newline.  The glyphs are placed from the left edge of the line.
@unsafe_ffi
pub func layoutRun(fonts: List[Font], text: String, rtl: Bool): TextLayout
  requires: fonts.count > 0
{
  layoutDirected(fonts, text, 0.0f32, if rtl { dirRtl } else { dirLtr })
}

/// The width of `text` as `layoutRun` lays it out.
@unsafe_ffi
pub func measureRun(fonts: List[Font], text: String, rtl: Bool): Float
  requires: fonts.count > 0
{
  layoutRun(fonts, text, rtl).width
}

@unsafe_ffi
func layoutDirected(fonts: List[Font], text: String, maxWidth: Float, dir: Int): TextLayout {
  val u = utf8Of(text)
  val placed: List[PlacedGlyph] = newList()
  val lead = fonts[0]
  var lineIndex = 0
  var widest = 0.0f32
  var ps = 0
  var more = true
  while more {
    var pe = ps
    while pe < u.length and nativeLoadByte(longToPtr(u.ptr), pe.toLong()) != 10u8 {
      pe = pe + 1
    }
    val para = paragraphOf(u, ps, pe, dir)
    val segs = segmentParagraph(fonts, u, para, dir == dirGuess)
    var line: List[Seg] = newList()
    var lineWidth = 0.0f32
    var pendingSpace: List[Seg] = newList()
    var pendingWidth = 0.0f32
    for seg in segs {
      if seg.forced {
        placeLine(placed, line, lineWidth, maxWidth, lead.ascent + lead.lineHeight * lineIndex.toFloat(), lineIndex, para)
        if lineWidth > widest {
          widest = lineWidth
        }
        lineIndex = lineIndex + 1
        line = newList()
        lineWidth = 0.0f32
        pendingSpace = newList()
        pendingWidth = 0.0f32
      }
      if seg.isSpace {
        if line.count > 0 {
          pendingSpace.add(seg)
          pendingWidth = pendingWidth + seg.width
        }
      } else {
        val needed = lineWidth + pendingWidth + seg.width
        if maxWidth > 0.0f32 and line.count > 0 and needed > maxWidth {
          placeLine(placed, line, lineWidth, maxWidth, lead.ascent + lead.lineHeight * lineIndex.toFloat(), lineIndex, para)
          if lineWidth > widest {
            widest = lineWidth
          }
          lineIndex = lineIndex + 1
          line = newList()
          lineWidth = 0.0f32
        } else {
          for sp in pendingSpace {
            line.add(sp)
          }
          lineWidth = lineWidth + pendingWidth
        }
        pendingSpace = newList()
        pendingWidth = 0.0f32
        line.add(seg)
        lineWidth = lineWidth + seg.width
      }
    }
    placeLine(placed, line, lineWidth, maxWidth, lead.ascent + lead.lineHeight * lineIndex.toFloat(), lineIndex, para)
    if lineWidth > widest {
      widest = lineWidth
    }
    lineIndex = lineIndex + 1
    if pe >= u.length {
      more = false
    } else {
      ps = pe + 1
    }
  }
  utf8Free(u)
  TextLayout(glyphs = placed, lineCount = lineIndex, width = widest, height = lead.lineHeight * lineIndex.toFloat())
}

/// The width of `text` on one line, in pixels.
@unsafe_ffi
pub func measureText(fonts: List[Font], text: String): Float
  requires: fonts.count > 0
{
  layoutText(fonts, text, 0.0f32).width
}
