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

// Mixed directions: a Hebrew word in an English line, a Hebrew line with English, a number and
// brackets, an Arabic line with a Latin word, and an English paragraph with Hebrew that wraps.
val bidiSceneText: String = "abc שלום def 123\nשלום (abc) 2026, עולם\nمرحبا Lyric مرحبا بك\nHebrew שלום עולם wraps שלום עולם here"

// The glyph of each character of `chars` (one font), in the order given.
func glyphsOf(f: Text.Font, chars: List[String]): List[Int] {
  val acc: List[Int] = newList()
  for c in chars {
    acc.add(Text.shape(f, c)[0].glyph)
  }
  acc
}

func sameGlyphs(layout: Text.TextLayout, want: List[Int]): Bool {
  if layout.glyphs.count != want.count {
    return false
  }
  var i = 0
  while i < want.count {
    if layout.glyphs[i].glyph != want[i] {
      return false
    }
    i = i + 1
  }
  true
}

func describeGlyphs(layout: Text.TextLayout): String {
  var r = ""
  for g in layout.glyphs {
    r = r + " " + g.glyph.toString()
  }
  r
}

func chars(s: String): List[String] {
  val acc: List[String] = newList()
  for c in Str.split(s, ",") {
    acc.add(if c == "_" { " " } else { c })
  }
  acc
}

// Glyphs come out of `layoutText` left to right on screen, so a check of visual order is a check of
// the glyph sequence.
func mixedDirectionChecks(chain: List[Text.Font], latin: Text.Font): Result[Unit, String] {
  val hebrewInLatin = Text.layoutText(chain, "abc אבג def", 0.0)
  if not sameGlyphs(hebrewInLatin, glyphsOf(latin, chars("a,b,c,_,ג,ב,א,_,d,e,f"))) {
    return Err(error = "a Hebrew word in an English line is not reversed in place:" + describeGlyphs(hebrewInLatin))
  }
  val latinInHebrew = Text.layoutText(chain, "אבג 123 abc", 0.0)
  if not sameGlyphs(latinInHebrew, glyphsOf(latin, chars("a,b,c,_,1,2,3,_,ג,ב,א"))) {
    return Err(
      error = "a number and a Latin word in a Hebrew line are not in visual order:" + describeGlyphs(latinInHebrew)
    )
  }
  // Several words in the other direction are one run: reversed as a whole, not word by word.
  val twoHebrewWords = Text.layoutText(chain, "abc אבג דהו def", 0.0)
  if not sameGlyphs(twoHebrewWords, glyphsOf(latin, chars("a,b,c,_,ו,ה,ד,_,ג,ב,א,_,d,e,f"))) {
    return Err(error = "two Hebrew words in an English line are not one reversed run:" + describeGlyphs(twoHebrewWords))
  }
  val englishInHebrew = Text.layoutText(chain, "אבג 12.5 abc def", 0.0)
  if not sameGlyphs(englishInHebrew, glyphsOf(latin, chars("a,b,c,_,d,e,f,_,1,2,.,5,_,ג,ב,א"))) {
    return Err(
      error = "English words and a number in a Hebrew line are not in visual order:" +
        describeGlyphs(englishInHebrew)
    )
  }
  val mirrored = Text.layoutText(chain, "א(ב)", 0.0)
  if not sameGlyphs(mirrored, glyphsOf(latin, chars("(,ב,),א"))) {
    return Err(error = "brackets in a Hebrew line are not mirrored:" + describeGlyphs(mirrored))
  }
  val arabicLatin = Text.layoutText(chain, "مرحبا Lyric", 0.0)
  val lyric = Text.shape(latin, "Lyric")
  if arabicLatin.glyphs.count < lyric.count or arabicLatin.glyphs[0].glyph != lyric[0].glyph {
    return Err(error = "a Latin word that ends an Arabic line is not at its left end")
  }
  val aligned = Text.layoutText(chain, "אבג abc", 300.0)
  var right = 0.0
  for g in aligned.glyphs {
    if g.x > right {
      right = g.x
    }
  }
  if right < 250.0 {
    return Err(error = "a mixed right to left paragraph is not aligned to the right")
  }
  // UAX #14: a hyphen-minus before a digit is a sign, not a place to break (LB25).
  val narrow = Text.measureText(chain, "ab -") + 2.0
  val signed = Text.layoutText(chain, "ab -12", narrow)
  if signed.lineCount != 2 or signed.glyphs[signed.glyphs.count - 3].line != 1 {
    return Err(error = "a line broke between a minus sign and its digits")
  }
  // Kinsoku: an ideographic full stop never starts a line.
  val twoIdeographs = Text.measureText(chain, "你好") + 1.0
  val kinsoku = Text.layoutText(chain, "你好。世界", twoIdeographs)
  if kinsoku.glyphs[2].line != kinsoku.glyphs[1].line {
    return Err(error = "an ideographic full stop started a line")
  }
  // Each line of a wrapped paragraph is reordered by itself: the Hebrew word that ends the first
  // line is drawn on that line, reversed, not moved to the next.
  val width = Text.measureText(chain, "abc אבג") + 4.0
  val wrapped = Text.layoutText(chain, "abc אבג def", width)
  if wrapped.lineCount != 2 or not sameGlyphPrefix(wrapped, glyphsOf(latin, chars("a,b,c,_,ג,ב,א"))) {
    return Err(error = "a wrapped line was not reordered by itself:" + describeGlyphs(wrapped))
  }
  Ok(value = ())
}

func sameGlyphPrefix(layout: Text.TextLayout, want: List[Int]): Bool {
  if layout.glyphs.count < want.count {
    return false
  }
  var i = 0
  while i < want.count {
    if layout.glyphs[i].glyph != want[i] or layout.glyphs[i].line != 0 {
      return false
    }
    i = i + 1
  }
  true
}

// Compares a scene drawn from `text` with the golden image at `path`, or writes it there when
// `update` is set.
func checkScene(
  chain: List[Text.Font],
  text: String,
  maxWidth: Float,
  w: Int,
  h: Int,
  path: String,
  update: Bool,
  label: String,
): Result[String, String] {
  val scene = Text.layoutText(chain, text, maxWidth)
  val big = Text.newAtlas(512, 512)
  val canvas = match render(chain, scene, big, w, h) { case Ok(c) -> c; case Err(e) -> return Err(error = e) }
  if update {
    return match File.writeBytes(path, pgm(canvas, w, h)) {
      case Ok(_) -> Ok(value = label + ": wrote " + path)
      case Err(_) -> Err(error = "cannot write " + path)
    }
  }
  val golden = match File.readBytes(path) { case Ok(g) -> g; case Err(_) -> return Err(error = "cannot read " + path) }
  val headerLength = ("P5\n" + w.toString() + " " + h.toString() + "\n255\n").length
  if golden.length != headerLength + w * h {
    return Err(error = "the golden image " + path + " has the wrong size")
  }
  var inked = 0
  var differing = 0
  var p = 0
  while p < w * h {
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
    return Err(error = label + " has almost no ink: " + inked.toString())
  }
  if differing * 100 > inked * 3 {
    return Err(
      error = label + " differs from the golden image: " + differing.toString() + " of " + inked.toString() +
        " inked pixels"
    )
  }
  Ok(value = label + ": " + differing.toString() + " of " + inked.toString() + " inked pixels differ")
}

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
  // A combining mark keeps the font of its base even when only a later font has it (#8827): U+3099
  // is in the CJK font alone, and a mark that left the Latin run would be shaped alone on a dotted circle.
  val marked = Text.layoutText(chain, "a゙b", 0.0)
  if countFont(marked, 1) != 0 {
    return fail("a combining mark left the font of its base")
  }
  val points = Text.layoutText(chain, "שָׁ", 0.0)
  if countFont(points, 0) != 3 {
    return fail("Hebrew points left the font of their letter")
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

  // A run of one direction (layoutRun) is shaped in the direction it is given, whatever its
  // characters are: right to left text is swapped (mirrored) and ordered right to left, left to
  // right text keeps its order even if it is Hebrew.
  val closeBracket = Text.shape(latin, ")")[0].glyph
  val openBracket = Text.shape(latin, "(")[0].glyph
  val mirrored = Text.layoutRun(chain, "(", true)
  if mirrored.glyphs.count != 1 or mirrored.glyphs[0].glyph != closeBracket {
    return fail("a right to left run did not mirror its bracket")
  }
  val straight = Text.layoutRun(chain, "(", false)
  if straight.glyphs.count != 1 or straight.glyphs[0].glyph != openBracket {
    return fail("a left to right run changed its bracket")
  }
  val alefBet = "אב"
  val alefGlyph = Text.shape(latin, "א")[0].glyph
  val betGlyph = Text.shape(latin, "ב")[0].glyph
  val hebrewLtr = Text.layoutRun(chain, alefBet, false)
  if hebrewLtr.glyphs.count != 2 or hebrewLtr.glyphs[0].glyph != alefGlyph or hebrewLtr.glyphs[1].glyph != betGlyph {
    return fail("a left to right run of Hebrew was reordered")
  }
  val hebrewRtl = Text.layoutRun(chain, alefBet, true)
  if hebrewRtl.glyphs.count != 2 or hebrewRtl.glyphs[0].glyph != betGlyph or hebrewRtl.glyphs[1].glyph != alefGlyph {
    return fail("a right to left run of Hebrew was not placed right to left")
  }
  val ab = Text.layoutRun(chain, "ab", true)
  val abGlyphs = Text.shape(latin, "ab")
  if ab.glyphs.count != 2 or ab.glyphs[0].glyph != abGlyphs[1].glyph {
    return fail("a right to left run of Latin letters was not placed right to left")
  }
  if Text.measureRun(chain, "Hello", false) != Text.runWidth(hello) {
    return fail("a run is not as wide as its shaped glyphs")
  }
  if hebrewRtl.lineCount != 1 {
    return fail("a run is not one line")
  }

  match mixedDirectionChecks(chain, latin) {
    case Ok(_) -> ()
    case Err(e) -> return fail(e)
  }

  // LYRIC_TEXT_GOLDEN and LYRIC_TEXT_GOLDEN_BIDI name the golden images of the two scenes;
  // LYRIC_TEXT_UPDATE=1 writes the scenes there instead of comparing.
  val update = Environment.getVarOrDefault("LYRIC_TEXT_UPDATE", "") == "1"
  val goldenPath = Environment.getVarOrDefault("LYRIC_TEXT_GOLDEN", "")
  if goldenPath.length > 0 {
    match checkScene(chain, sceneText, 360.0, 384, 160, goldenPath, update, "golden") {
      case Ok(m) -> Console.println(m)
      case Err(e) -> return fail(e)
    }
  }
  val bidiPath = Environment.getVarOrDefault("LYRIC_TEXT_GOLDEN_BIDI", "")
  if bidiPath.length > 0 {
    match checkScene(chain, bidiSceneText, 360.0, 384, 224, bidiPath, update, "golden bidi") {
      case Ok(m) -> Console.println(m)
      case Err(e) -> return fail(e)
    }
  }
  Console.println(
    "hello: " + hello.count.toString() + " glyphs, AV kerned, arabic: " + arabic.count.toString() +
      " glyphs, H ink > 40, fallback + wrap ok, runs ok, mixed directions ok"
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
