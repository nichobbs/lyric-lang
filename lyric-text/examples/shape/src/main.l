package Text.Examples.Shape

import Std.Console as Console
import Std.Collections
import Std.Environment as Environment
import Std.File as File
import Std.Buffer as Buf
import Std.String as Str
import Text

func fail(msg: String): Int {
  Console.println("FAIL: " + msg)
  1
}

func load(lib: Text.TextLib, id: Int, path: String, index: Int, size: Int): Result[Text.Font, String] {
  match File.readBytes(path) {
    case Ok(bytes) -> Text.openFont(lib, id, bytes, index, size)
    case Err(e) -> Err(error = "cannot read " + path)
  }
}

func countFont(layout: Text.TextLayout, font: Int): Int {
  var n = 0
  for g in layout.glyphs {
    if g.font == font {
      n = n + 1
    }
  }
  n
}

// Draws a layout into a w by h coverage canvas through an atlas.
func render(
  chain: List[Text.Font], layout: Text.TextLayout, atlas: Text.Atlas, w: Int, h: Int
): Result[buffer[Byte], String] {
  var canvas = Buf.filled(w * h, 0u8)
  for g in layout.glyphs {
    val r = match Text.atlasGlyph(atlas, chain[g.font], g.glyph) { case Ok(r) -> r; case Err(e) -> return Err(error = e) }
    val ox = g.x.toInt() + r.left
    val oy = g.y.toInt() - r.top
    var row = 0
    while row < r.height {
      var col = 0
      while col < r.width {
        val x = ox + col
        val y = oy + row
        if x >= 0 and x < w and y >= 0 and y < h {
          val v = atlas.pixels[(r.y + row) * atlas.width + r.x + col]
          if v > canvas[y * w + x] {
            canvas[y * w + x] = v
          }
        }
        col = col + 1
      }
      row = row + 1
    }
  }
  Ok(value = canvas)
}

// A binary PGM of the canvas.
func pgm(canvas: buffer[Byte], w: Int, h: Int): slice[Byte] {
  val header = "P5\n" + w.toString() + " " + h.toString() + "\n255\n"
  var file = Buf.filled(header.length + canvas.length, 0u8)
  var i = 0
  while i < header.length {
    file[i] = header[i].toInt().toByte()
    i = i + 1
  }
  var k = 0
  while k < canvas.length {
    file[header.length + k] = canvas[k]
    k = k + 1
  }
  Buf.toSlice(file)
}

val sceneText: String = "Hello, Lyric! مرحبا 你好\nwrapped text wraps at the column width, 你好世界"

func run(lib: Text.TextLib, latinPath: String, cjkPath: String): Int {
  val latin = match load(lib, 1, latinPath, 0, 32) { case Ok(f) -> f; case Err(e) -> return fail(e) }
  val cjk = match load(lib, 2, cjkPath, 0, 32) { case Ok(f) -> f; case Err(e) -> return fail(e) }

  // Shaping: one glyph per letter, positive advances, a clustered run in logical order.
  val hello = Text.shape(latin, "Hello")
  if hello.count != 5 {
    return fail("Hello shaped to " + hello.count.toString() + " glyphs")
  }
  if Text.runWidth(hello) < 40.0 or Text.runWidth(hello) > 120.0 {
    return fail("Hello is an implausible width")
  }
  if hello[0].cluster != 0 or hello[4].cluster != 4 {
    return fail("Hello clusters are not 0..4")
  }

  // Kerning: "AV" is tighter than the sum of "A" and "V".
  val av = Text.runWidth(Text.shape(latin, "AV"))
  val apart = Text.runWidth(Text.shape(latin, "A")) + Text.runWidth(Text.shape(latin, "V"))
  if av >= apart {
    return fail("AV is not kerned")
  }

  // Arabic: joining forms shape five letters into five glyphs, in visual order, wider than zero.
  val arabic = Text.shape(latin, "مرحبا")
  if arabic.count != 5 {
    return fail("Arabic shaped to " + arabic.count.toString() + " glyphs")
  }
  if arabic[0].cluster != 8 or arabic[4].cluster != 0 {
    return fail("Arabic is not in visual order")
  }

  // Rasterising: 'H' has ink, a space has none.
  val hGlyph = hello[0].glyph
  val hBitmap = match Text.rasterize(latin, hGlyph) { case Ok(b) -> b; case Err(e) -> return fail(e) }
  if hBitmap.width <= 0 or hBitmap.height <= 0 {
    return fail("H has no bitmap")
  }
  var ink = 0
  var i = 0
  while i < hBitmap.width * hBitmap.height {
    if hBitmap.pixels[i] > 127u8 {
      ink = ink + 1
    }
    i = i + 1
  }
  if ink < 40 {
    return fail("H has too little ink: " + ink.toString())
  }
  val space = Text.shape(latin, " ")
  val spaceBitmap = match Text.rasterize(latin, space[0].glyph) { case Ok(b) -> b; case Err(e) -> return fail(e) }
  if spaceBitmap.width != 0 {
    return fail("a space has ink")
  }

  // Atlas: glyphs pack without overlap and are found again.
  val atlas = Text.newAtlas(256, 256)
  val a = match Text.atlasGlyph(atlas, latin, hGlyph) { case Ok(r) -> r; case Err(e) -> return fail(e) }
  val b = match Text.atlasGlyph(atlas, latin, hello[1].glyph) { case Ok(r) -> r; case Err(e) -> return fail(e) }
  val again = match Text.atlasGlyph(atlas, latin, hGlyph) { case Ok(r) -> r; case Err(e) -> return fail(e) }
  if again.x != a.x or again.y != a.y {
    return fail("a glyph was packed twice")
  }
  if b.x < a.x + a.width and b.y == a.y {
    return fail("two glyphs overlap in the atlas")
  }

  // Fallback and line breaking.
  val chain: List[Text.Font] = newList()
  chain.add(latin)
  chain.add(cjk)
  val mixed = Text.layoutText(chain, "Hi 你好", 0.0)
  if countFont(mixed, 1) != 2 {
    return fail("the CJK characters did not fall back to the second font")
  }
  if countFont(mixed, 0) < 3 {
    return fail("the Latin characters left the first font")
  }
  val wrapped = Text.layoutText(chain, "alpha beta gamma delta", 200.0)
  if wrapped.lineCount < 2 {
    return fail("a 200 px column did not wrap")
  }
  if wrapped.width > 200.5 {
    return fail("a wrapped line is wider than the column")
  }
  val lines = Text.layoutText(chain, "one\ntwo\nthree", 0.0)
  if lines.lineCount != 3 {
    return fail("newlines did not break lines")
  }
  val cjkWrapped = Text.layoutText(chain, "你好你好你好你好", 80.0)
  if cjkWrapped.lineCount < 2 {
    return fail("ideographs did not break between characters")
  }

  // A right-to-left paragraph lays its words bytes right to left and aligns to the right edge.
  val rtl = Text.layoutText(chain, "مرحبا بك", 200.0)
  var minX = 1000000.0
  var maxX = 0.0
  for g in rtl.glyphs {
    if g.x < minX {
      minX = g.x
    }
    if g.x > maxX {
      maxX = g.x
    }
  }
  if maxX < 150.0 {
    return fail("the right-to-left paragraph is not right-aligned")
  }

  val pgmPath = Environment.getVarOrDefault("LYRIC_TEXT_RENDER_PGM", "")
  if pgmPath.length > 0 {
    val scene = Text.layoutText(chain, "Hello, Lyric! مرحبا 你好\nwrapped text wraps at the column width, 你好世界", 360.0)
    val big = Text.newAtlas(512, 512)
    val canvas = match render(chain, scene, big, 384, 160) { case Ok(c) -> c; case Err(e) -> return fail(e) }
    match File.writeBytes(pgmPath, pgm(canvas, 384, 160)) {
      case Ok(_) -> ()
      case Err(_) -> return fail("cannot write " + pgmPath)
    }
  }
  val goldenPath = Environment.getVarOrDefault("LYRIC_TEXT_GOLDEN", "")
  if goldenPath.length > 0 {
    val scene = Text.layoutText(chain, sceneText, 360.0)
    val big = Text.newAtlas(512, 512)
    val canvas = match render(chain, scene, big, 384, 160) { case Ok(c) -> c; case Err(e) -> return fail(e) }
    val golden = match File.readBytes(goldenPath) {
      case Ok(g) -> g
      case Err(_) -> return fail("cannot read " + goldenPath)
    }
    val headerLength = "P5\n384 160\n255\n".length
    if golden.length != headerLength + 384 * 160 {
      return fail("the golden image has the wrong size")
    }
    var inked = 0
    var differing = 0
    var p = 0
    while p < 384 * 160 {
      val got = canvas[p].toInt()
      val want = golden[headerLength + p].toInt()
      if got > 32 or want > 32 {
        inked = inked + 1
      }
      val d = got - want
      if d > 64 or d < -64 {
        differing = differing + 1
      }
      p = p + 1
    }
    if inked < 2000 {
      return fail("the scene has almost no ink: " + inked.toString())
    }
    if differing * 100 > inked * 3 {
      return fail(
        "scene differs from the golden image: " + differing.toString() + " of " + inked.toString() + " inked pixels"
      )
    }
    Console.println("golden: " + differing.toString() + " of " + inked.toString() + " inked pixels differ")
  }
  Console.println(
    "hello: " + hello.count.toString() + " glyphs, AV kerned, arabic: " + arabic.count.toString() +
      " glyphs, H ink > 40, fallback + wrap ok"
  )
  Text.closeFont(latin)
  Text.closeFont(cjk)
  0
}

func main(): Int {
  val latin = Environment.getVarOrDefault("LYRIC_TEXT_FONT_LATIN", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
  val cjk = Environment.getVarOrDefault("LYRIC_TEXT_FONT_CJK", "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc")
  val lib = match Text.initText() { case Ok(l) -> l; case Err(e) -> return fail(e) }
  val code = run(lib, latin, cjk)
  Text.closeText(lib)
  code
}
