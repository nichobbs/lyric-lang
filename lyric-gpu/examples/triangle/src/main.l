//! triangle: renders a 64x64 triangle into an offscreen target and compares it with a
//! golden image.
//!   triangle <golden.rgba>            compare; exit 1 when too many pixels differ
//!   triangle --update <golden.rgba>   write the rendered pixels as the new golden
//! A software rasteriser and a hardware one place edge pixels differently, so a pixel
//! counts as different only when a channel is off by more than `channelTolerance`, and
//! up to `pixelBudget` of them may differ.
package Gpu.Examples.Triangle

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Buffer as Buf
import Std.Environment as Environment
import Std.File as File
import Std.Errors
import Gpu

val size: Int = 64

val channelTolerance: Int = 8

val pixelBudget: Int = 80

val shader: String = "@vertex\nfn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {\n  var p = array<vec2<f32>, 3>(vec2<f32>(0.0, 0.8), vec2<f32>(-0.8, -0.8), vec2<f32>(0.8, -0.8));\n  return vec4<f32>(p[i], 0.0, 1.0);\n}\n@fragment\nfn fs() -> @location(0) vec4<f32> {\n  return vec4<f32>(1.0, 0.0, 0.0, 1.0);\n}\n"

val noLayouts: List[Gpu.VertexLayout] = []

val noBuffers: List[Gpu.Buffer] = []

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func channelDiff(a: Byte, b: Byte): Int {
  val x = a.toInt()
  val y = b.toInt()
  if x > y then x - y else y - x
}

func render(d: Gpu.Device): Result[buffer[Byte], String] {
  val target = Gpu.createRenderTarget(d, size, size)
  val pipeline = match Gpu.createRenderPipeline(d, shader, "vs", "fs", noLayouts) {
    case Ok(p) -> p
    case Err(e) -> return Err(error = e)
  }
  val draws: List[Gpu.Draw] = newList()
  draws.add(Gpu.Draw(pipeline = pipeline, bindGroup = None, vertexBuffers = noBuffers, vertexCount = 3))
  match Gpu.render(d, target, 0.0, 0.0, 1.0, 1.0, draws) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  val pixels = Gpu.readPixels(d, target)
  Gpu.releaseRenderPipeline(pipeline)
  Gpu.releaseRenderTarget(target)
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

func run(d: Gpu.Device, args: slice[String]): Int {
  // `Environment.args` follows the host's convention on whether argv0 comes first, so the
  // path is read from the end.
  if args.length == 0 {
    return fail("usage: triangle [--update] <golden.rgba>")
  }
  val path = args[args.length - 1]
  val update = args.length >= 2 and args[args.length - 2] == "--update"
  val pixels = match render(d) { case Ok(b) -> b; case Err(e) -> return fail(e) }
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
  val body: (Gpu.Device) -> Int = { d: Gpu.Device -> run(d, args) }
  match Gpu.withDevice(body) {
    case Err(e) -> fail(e)
    case Ok(rc) -> rc
  }
}
