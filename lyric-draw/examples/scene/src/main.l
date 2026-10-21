//! scene: a card with a shadow, a border, rounded shapes, an image, and clipped and wrapped
//! Latin, Arabic and CJK text, drawn offscreen with Draw and compared with a golden image.
//!   scene <golden.rgba>            compare; exit 1 when too many pixels differ
//!   scene --update <golden.rgba>   write the rendered pixels as the new golden
//!   scene --stress                 time a text-heavy 1280x720 frame (about 3000 glyphs)
//! Fonts: LYRIC_TEXT_FONT_LATIN (DejaVu Sans) and LYRIC_TEXT_FONT_CJK (WenQuanYi Zen Hei).
//! A software and a hardware rasteriser, and different FreeType versions, place edge pixels
//! a little differently, so a pixel counts as differing past a per-channel tolerance and the
//! run fails past a differing-pixel budget.
package Draw.Examples.Scene

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Buffer as Buf
import Std.Environment as Environment
import Std.File as File
import Std.Time as Time
import Std.Errors
import Gpu
import Draw
import Text

val width: Int = 256

val height: Int = 192

val channelTolerance: Int = 24

val pixelBudget: Int = 600

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func channelDiff(a: Byte, b: Byte): Int {
  val x = a.toInt()
  val y = b.toInt()
  if x > y then x - y else y - x
}

func loadFont(lib: Text.TextLib, id: Int, path: String, size: Int): Result[Text.Font, String] {
  match File.readBytes(path) {
    case Ok(bytes) -> Text.openFont(lib, id, bytes, 0, size)
    case Err(_) -> Err(error = "cannot read " + path)
  }
}

// A 16x16 checkerboard of translucent red and opaque blue squares.
func checker(): buffer[Byte] {
  var px = Buf.filled(16 * 16 * 4, 0u8)
  var y = 0
  while y < 16 {
    var x = 0
    while x < 16 {
      val on = (x / 4 + y / 4) % 2 == 0
      val i = (y * 16 + x) * 4
      if on {
        px[i] = 230u8
        px[i + 1] = 40u8
        px[i + 2] = 40u8
        px[i + 3] = 160u8
      } else {
        px[i] = 30u8
        px[i + 1] = 60u8
        px[i + 2] = 220u8
        px[i + 3] = 255u8
      }
      x = x + 1
    }
    y = y + 1
  }
  px
}

func paint(p: Draw.Painter, title: List[Text.Font], body: List[Text.Font]): Result[Unit, String] {
  val card = Draw.Rect(x = 12.0, y = 12.0, width = 232.0, height = 168.0)
  Draw.drawShadow(
    p,
    Draw.Rect(x = 12.0, y = 16.0, width = 232.0, height = 168.0),
    12.0,
    10.0,
    Draw.rgba(0.0, 0.0, 0.0, 0.4)
  )
  Draw.fillRoundedRect(p, card, 12.0, Draw.rgb(1.0, 1.0, 1.0))
  Draw.strokeRoundedRect(p, card, 12.0, 1.0, Draw.rgb(0.75, 0.78, 0.84))
  Draw.fillRoundedRect(p, Draw.Rect(x = 12.0, y = 12.0, width = 232.0, height = 34.0), 12.0, Draw.rgb(0.2, 0.4, 0.9))
  Draw.fillRect(p, Draw.Rect(x = 12.0, y = 30.0, width = 232.0, height = 16.0), Draw.rgb(0.2, 0.4, 0.9))
  match Draw.drawText(p, title, "Lyric Draw", 24.0, 14.0, 0.0, Draw.rgb(1.0, 1.0, 1.0)) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  match Draw.drawText(p, body, "Latin, مرحبا, 你好 wrap in a narrow column", 24.0, 54.0, 150.0, Draw.rgb(0.1, 0.1, 0.15)) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  val image = match Draw.createImage(p, 16, 16, checker(), false) { case Ok(i) -> i; case Err(e) -> return Err(error = e) }
  Draw.drawImage(p, image, Draw.Rect(x = 184.0, y = 58.0, width = 48.0, height = 48.0), Draw.rgb(1.0, 1.0, 1.0))
  Draw.fillRoundedRect(p, Draw.Rect(x = 190.0, y = 118.0, width = 36.0, height = 36.0), 18.0, Draw.rgb(0.15, 0.7, 0.4))
  Draw.pushClip(p, Draw.Rect(x = 24.0, y = 128.0, width = 140.0, height = 36.0))
  Draw.fillRoundedRect(
    p,
    Draw.Rect(x = 14.0, y = 124.0, width = 300.0, height = 22.0),
    6.0,
    Draw.rgba(1.0, 0.8, 0.2, 0.6)
  )
  val clipped = Draw.drawText(
    p,
    body,
    "clipped text that runs far past the clip rectangle",
    28.0,
    130.0,
    0.0,
    Draw.rgb(0.6, 0.1, 0.1)
  )
  Draw.popClip(p)
  match clipped {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  // The image is only referenced until finish, so it is released by the caller afterwards.
  Ok(value = ())
}

func render(d: Gpu.Device, lib: Text.TextLib, latin: String, cjk: String): Result[buffer[Byte], String] {
  val title: List[Text.Font] = newList()
  val body: List[Text.Font] = newList()
  title.add(match loadFont(lib, 1, latin, 18) { case Ok(f) -> f; case Err(e) -> return Err(error = e) })
  title.add(match loadFont(lib, 2, cjk, 18) { case Ok(f) -> f; case Err(e) -> return Err(error = e) })
  body.add(match loadFont(lib, 3, latin, 14) { case Ok(f) -> f; case Err(e) -> return Err(error = e) })
  body.add(match loadFont(lib, 4, cjk, 14) { case Ok(f) -> f; case Err(e) -> return Err(error = e) })
  val target = Gpu.createRenderTarget(d, width, height)
  val painter = match Draw.newPainter(d, Gpu.formatRgba8) { case Ok(p) -> p; case Err(e) -> return Err(error = e) }
  Draw.beginFrame(painter, width, height)
  match paint(painter, title, body) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  match Draw.finish(painter, target, Draw.rgb(0.93, 0.94, 0.97)) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  val pixels = Gpu.readPixels(d, target)
  Draw.releasePainter(painter)
  Gpu.releaseRenderTarget(target)
  for f in title {
    Text.closeFont(f)
  }
  for f in body {
    Text.closeFont(f)
  }
  pixels
}

func check(pixels: buffer[Byte], golden: slice[Byte]): Int {
  if golden.length != pixels.length {
    return fail("the golden image has " + golden.length.toString() + " bytes, the render " + pixels.length.toString())
  }
  var differing = 0
  var p = 0
  while p < pixels.length {
    if channelDiff(pixels[p], golden[p]) > channelTolerance or channelDiff(pixels[p + 1], golden[p + 1]) > channelTolerance or channelDiff(pixels[p + 2], golden[p + 2]) > channelTolerance or channelDiff(pixels[p + 3], golden[p + 3]) > channelTolerance {
      differing = differing + 1
    }
    p = p + 4
  }
  Console.println(
    "pixels differing from the golden image: " + differing.toString() + " (budget " + pixelBudget.toString() + ")"
  )
  if differing > pixelBudget then 1 else 0
}

val stressWidth: Int = 1280

val stressHeight: Int = 720

val stressFrames: Int = 10

val stressBudgetMillis: Long = 100

// A text-heavy frame: a page of mixed Latin, Arabic and CJK text drawn ten times over, timed.
func stress(d: Gpu.Device, lib: Text.TextLib, latin: String, cjk: String): Int {
  val fonts: List[Text.Font] = newList()
  fonts.add(match loadFont(lib, 1, latin, 16) { case Ok(f) -> f; case Err(e) -> return fail(e) })
  fonts.add(match loadFont(lib, 2, cjk, 16) { case Ok(f) -> f; case Err(e) -> return fail(e) })
  val target = Gpu.createRenderTarget(d, stressWidth, stressHeight)
  val painter = match Draw.newPainter(d, Gpu.formatRgba8) { case Ok(p) -> p; case Err(e) -> return fail(e) }
  val sentence = "The quick brown fox jumps over the lazy dog. مرحبا بالعالم 你好世界，这是文字测试。 "
  var page = ""
  var k = 0
  while k < 24 {
    page = page + sentence
    k = k + 1
  }
  var glyphs = 0
  val started = Time.nowEpochMillis()
  var frame = 0
  while frame < stressFrames {
    Draw.beginFrame(painter, stressWidth, stressHeight)
    var column = 0
    while column < 3 {
      val laid = match Draw.drawText(painter, fonts, page, 16.0 + (column * 420).toFloat(), 16.0, 400.0, Draw.rgb(0.1, 0.1, 0.15)) {
        case Ok(l) -> l
        case Err(e) -> return fail(e)
      }
      glyphs = laid.glyphs.count
      column = column + 1
    }
    match Draw.finish(painter, target, Draw.rgb(1.0, 1.0, 1.0)) {
      case Ok(_) -> ()
      case Err(e) -> return fail(e)
    }
    frame = frame + 1
  }
  val pixels = match Gpu.readPixels(d, target) { case Ok(b) -> b; case Err(e) -> return fail(e) }
  val perFrame = (Time.nowEpochMillis() - started) / stressFrames.toLong()
  Draw.releasePainter(painter)
  Gpu.releaseRenderTarget(target)
  for f in fonts {
    Text.closeFont(f)
  }
  var ink = 0
  var i = 0
  while i < pixels.length {
    if pixels[i] < 128u8 {
      ink = ink + 1
    }
    i = i + 4
  }
  Console.println(
    "stress: " + (glyphs * 3).toString() + " glyphs per frame, " + perFrame.toString() + " ms per frame (budget " +
      stressBudgetMillis.toString() +
      "), " +
      ink.toString() +
      " dark pixels"
  )
  if ink < 5000 {
    return fail("the stress frame has almost no ink")
  }
  if perFrame > stressBudgetMillis then 1 else 0
}

func run(d: Gpu.Device, lib: Text.TextLib, args: slice[String]): Int {
  if args.length == 0 {
    return fail("usage: scene [--update] <golden.rgba>")
  }
  val latin = Environment.getVarOrDefault("LYRIC_TEXT_FONT_LATIN", "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")
  val cjk = Environment.getVarOrDefault("LYRIC_TEXT_FONT_CJK", "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc")
  if args[args.length - 1] == "--stress" {
    return stress(d, lib, latin, cjk)
  }
  val path = args[args.length - 1]
  val update = args.length >= 2 and args[args.length - 2] == "--update"
  val pixels = match render(d, lib, latin, cjk) { case Ok(b) -> b; case Err(e) -> return fail(e) }
  if update {
    match File.writeBytes(path, Buf.toSlice(pixels)) {
      case Ok(_) -> {
        Console.println("wrote " + path)
        0
      }
      case Err(e) -> fail("cannot write " + path + ": " + IOError.message(e))
    }
  } else {
    match File.readBytes(path) {
      case Ok(golden) -> check(pixels, golden)
      case Err(e) -> fail("cannot read " + path + ": " + IOError.message(e))
    }
  }
}

func main(): Int {
  val args = Environment.args()
  val lib = match Text.initText() { case Ok(l) -> l; case Err(e) -> return fail(e) }
  val body: (Gpu.Device) -> Int = { d: Gpu.Device -> run(d, lib, args) }
  val code = match Gpu.withDevice(body) { case Err(e) -> fail(e); case Ok(rc) -> rc }
  Text.closeText(lib)
  code
}
