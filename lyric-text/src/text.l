//! text.l - Text: font loading, shaping, glyph rasterisation and line layout for
//! `--target native`, over FreeType and HarfBuzz (docs/67 phase G6).
//!
//! Every native object is an opaque `Long` handle inside a record, so no `NativePtr` crosses this
//! package's public surface.  A `Font` is one face at one pixel size; a fallback chain is a
//! `List[Font]` and `layoutText` picks, for each character, the first font in the chain that has
//! a glyph for it.
//!
//! Shaping is HarfBuzz's: ligatures, kerning, Arabic joining and Indic reordering come from the
//! font's own tables.  Layout is a greedy line breaker over simplified break opportunities
//! (after a space or hyphen, and between ideographs, kana and Hangul syllables).  A paragraph has
//! one base direction, taken from its first strong character; right-to-left paragraphs lay their
//! words out right to left.  Text that mixes directions inside one paragraph is not reordered
//! (bidirectional text through FriBidi is tracked in #8410).
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

// FT_LOAD_NO_HINTING: advances and outlines at the exact scale, so shaping and rasterising agree.
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

@unsafe_ffi
func loadPointer(p: NativePtr[Byte], offset: Long): NativePtr[Byte] {
  longToPtr(loadInt64(p, offset))
}

// Offsets into FreeType's public structs on 64-bit targets, checked by native/text_layout_check.c.
val faceGlyphOffset: Long = 152

val faceSizeOffset: Long = 160

val sizeMetricsAscender: Long = 48

val sizeMetricsDescender: Long = 56

val sizeMetricsHeight: Long = 64

val slotAdvanceOffset: Long = 128

val slotBitmapOffset: Long = 152

val slotBitmapLeftOffset: Long = 192

val slotBitmapTopOffset: Long = 196

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
  val rc = Ft.FT_New_Memory_Face(longToPtr(lib.raw), data, n.toLong(), faceIndex.toLong(), nativeAddrOf(face))
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
  val ascender = loadInt64(metrics, sizeMetricsAscender)
  val descender = loadInt64(metrics, sizeMetricsDescender)
  val height = loadInt64(metrics, sizeMetricsHeight)
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
  Ft.FT_Get_Char_Index(longToPtr(f.face), codepoint.toLong()) != 0
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
/// Direction, script and language are guessed from the range's characters.
@unsafe_ffi
func shapeRange(f: Font, u: Utf8, start: Int, stop: Int): List[ShapedGlyph] {
  val buf = Hb.hb_buffer_create()
  Hb.hb_buffer_add_utf8(buf, longToPtr(u.ptr), u.length, start, stop - start)
  Hb.hb_buffer_guess_segment_properties(buf)
  Hb.hb_shape(longToPtr(f.hb), buf, nativeNullPtr(), 0)
  val count = Hb.hb_buffer_get_length(buf)
  val infos = Hb.hb_buffer_get_glyph_infos(buf, nativeNullPtr())
  val positions = Hb.hb_buffer_get_glyph_positions(buf, nativeNullPtr())
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
  val glyphs = shapeRange(f, u, 0, u.length)
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
pub record Atlas {
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

func isCjkCp(cp: Int): Bool {
  (cp >= 12352 and cp <= 12543) or (cp >= 13312 and cp <= 19903) or (cp >= 19968 and cp <= 40959) or
    (cp >= 44032 and cp <= 55215) or
    (cp >= 63744 and cp <= 64255) or
    (cp >= 65280 and cp <= 65519) or
    (cp >= 12288 and cp <= 12351)
}

// Closing punctuation never starts a line, opening punctuation never ends one.
func noBreakBeforeCp(cp: Int): Bool {
  cp == 12289 or cp == 12290 or cp == 65292 or cp == 65294 or cp == 65289 or cp == 12301 or cp == 12303 or cp == 12305 or
    cp == 65281 or
    cp == 65311 or
    cp == 65306 or
    cp == 65307
}

func noBreakAfterCp(cp: Int): Bool {
  cp == 12300 or cp == 12302 or cp == 12304 or cp == 65288
}

func isRtlCp(cp: Int): Bool {
  (cp >= 1424 and cp <= 2303) or (cp >= 64285 and cp <= 65023) or (cp >= 65136 and cp <= 65279)
}

// A character that takes the font of the one before it: spaces, joiners, combining marks.
func isNeutralCp(cp: Int): Bool {
  cp <= 32 or cp == 160 or (cp >= 768 and cp <= 879) or (cp >= 1552 and cp <= 1562) or (cp >= 1611 and cp <= 1631) or
    (cp >= 8203 and cp <= 8207) or
    (cp >= 8400 and cp <= 8447) or
    (cp >= 65024 and cp <= 65039)
}

func isLetterCp(cp: Int): Bool {
  (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122) or cp >= 192
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

func paragraphIsRtl(u: Utf8, start: Int, stop: Int): Bool {
  var i = start
  while i < stop {
    val cp = codepointAt(u, i)
    if isRtlCp(cp) {
      return true
    }
    if isLetterCp(cp) {
      return false
    }
    i = scalarEnd(u, i)
  }
  false
}

record Run {
  font: Int
  glyphs: List[ShapedGlyph]
  width: Float
}

record Seg {
  runs: List[Run]
  width: Float
  isSpace: Bool
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

// Shapes the byte range as one segment, split into runs where the chain's font changes.
func shapeSegment(fonts: List[Font], u: Utf8, start: Int, stop: Int, isSpace: Bool): Seg {
  val runs: List[Run] = newList()
  var runStart = start
  var runFont = -1
  var i = start
  while i < stop {
    val cp = codepointAt(u, i)
    val f = if isNeutralCp(cp) and runFont >= 0 { runFont } else { fontFor(fonts, cp) }
    if runFont >= 0 and f != runFont {
      val g = shapeRange(fonts[runFont], u, runStart, i)
      runs.add(Run(font = runFont, glyphs = g, width = runWidth(g)))
      runStart = i
    }
    runFont = f
    i = scalarEnd(u, i)
  }
  if runFont < 0 {
    runFont = 0
  }
  if stop > runStart or runs.count == 0 {
    val g = shapeRange(fonts[runFont], u, runStart, stop)
    runs.add(Run(font = runFont, glyphs = g, width = runWidth(g)))
  }
  var w = 0.0f32
  for r in runs {
    w = w + r.width
  }
  Seg(runs = runs, width = w, isSpace = isSpace)
}

// Splits a paragraph at break opportunities into words and space runs, shaped.
func segmentParagraph(fonts: List[Font], u: Utf8, start: Int, stop: Int): List[Seg] {
  val segs: List[Seg] = newList()
  var segStart = start
  var prevCp = -1
  var i = start
  while i < stop {
    val cp = codepointAt(u, i)
    if prevCp >= 0 {
      val spaceChange = isSpaceCp(prevCp) != isSpaceCp(cp)
      val afterHyphen = prevCp == 45 and not isSpaceCp(cp)
      val cjkBreak = (isCjkCp(prevCp) or isCjkCp(cp)) and not noBreakBeforeCp(cp) and not noBreakAfterCp(prevCp) and
        not isSpaceCp(prevCp) and
        not isSpaceCp(cp)
      if spaceChange or afterHyphen or cjkBreak {
        segs.add(shapeSegment(fonts, u, segStart, i, isSpaceCp(prevCp)))
        segStart = i
      }
    }
    prevCp = cp
    i = scalarEnd(u, i)
  }
  if stop > segStart {
    segs.add(shapeSegment(fonts, u, segStart, stop, isSpaceCp(prevCp)))
  }
  segs
}

func placeSeg(placed: List[PlacedGlyph], seg: Seg, startX: Float, baseline: Float, lineIndex: Int, rtl: Bool): Float {
  var x = startX
  var r = 0
  while r < seg.runs.count {
    val run = if rtl { seg.runs[seg.runs.count - 1 - r] } else { seg.runs[r] }
    for g in run.glyphs {
      placed.add(
        PlacedGlyph(font = run.font, glyph = g.glyph, x = x + g.xOffset, y = baseline - g.yOffset, line = lineIndex)
      )
      x = x + g.xAdvance
    }
    r = r + 1
  }
  x
}

// Places one line's segments (logical order) and returns its width.
func placeLine(
  placed: List[PlacedGlyph],
  line: List[Seg],
  lineWidth: Float,
  maxWidth: Float,
  baseline: Float,
  lineIndex: Int,
  rtl: Bool,
): Unit {
  var x = if rtl and maxWidth > 0.0f32 { maxWidth - lineWidth } else { 0.0f32 }
  var s = 0
  while s < line.count {
    val seg = if rtl { line[line.count - 1 - s] } else { line[s] }
    x = placeSeg(placed, seg, x, baseline, lineIndex, rtl)
    s = s + 1
  }
}

/// Lays `text` out in a column `maxWidth` pixels wide (no wrapping when it is not positive),
/// breaking lines at spaces, hyphens and between ideographs, and at `\n`.  `fonts` is the
/// fallback chain, its first font setting the line height.
@unsafe_ffi
pub func layoutText(fonts: List[Font], text: String, maxWidth: Float): TextLayout
  requires: fonts.count > 0
{
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
    val rtl = paragraphIsRtl(u, ps, pe)
    val segs = segmentParagraph(fonts, u, ps, pe)
    var line: List[Seg] = newList()
    var lineWidth = 0.0f32
    var pendingSpace: List[Seg] = newList()
    var pendingWidth = 0.0f32
    for seg in segs {
      if seg.isSpace {
        if line.count > 0 {
          pendingSpace.add(seg)
          pendingWidth = pendingWidth + seg.width
        }
      } else {
        val needed = lineWidth + pendingWidth + seg.width
        if maxWidth > 0.0f32 and line.count > 0 and needed > maxWidth {
          placeLine(placed, line, lineWidth, maxWidth, lead.ascent + lead.lineHeight * lineIndex.toFloat(), lineIndex, rtl)
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
    placeLine(placed, line, lineWidth, maxWidth, lead.ascent + lead.lineHeight * lineIndex.toFloat(), lineIndex, rtl)
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
