//! quad: a 2x2 texture (red, green / blue, white) drawn nearest-filtered on a quad of two
//! triangles from a vertex buffer, multiplied by a tint read from a uniform buffer, and
//! compared with a golden image.
//!   quad <golden.rgba>            compare; exit 1 when too many pixels differ
//!   quad --update <golden.rgba>   write the rendered pixels as the new golden
//! See `triangle` for the tolerance.
package Gpu.Examples.Quad

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

val shader: String = "struct Tint { color: vec4<f32> }\n@group(0) @binding(0) var<uniform> tint: Tint;\n@group(0) @binding(1) var tex: texture_2d<f32>;\n@group(0) @binding(2) var samp: sampler;\nstruct VOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> }\n@vertex\nfn vs(@location(0) pos: vec2<f32>, @location(1) uv: vec2<f32>) -> VOut {\n  var out: VOut;\n  out.pos = vec4<f32>(pos, 0.0, 1.0);\n  out.uv = uv;\n  return out;\n}\n@fragment\nfn fs(in: VOut) -> @location(0) vec4<f32> {\n  return textureSample(tex, samp, in.uv) * tint.color;\n}\n"

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func channelDiff(a: Byte, b: Byte): Int {
  val x = a.toInt()
  val y = b.toInt()
  if x > y then x - y else y - x
}

func texels(): buffer[Byte] {
  Buf.fromSlice([255u8, 0u8, 0u8, 255u8, 0u8, 255u8, 0u8, 255u8, 0u8, 0u8, 255u8, 255u8, 255u8, 255u8, 255u8, 255u8])
}

// x, y, u, v for two triangles covering [-0.8, 0.8] in both axes (v grows downwards).
func quadVertices(): buffer[Float] {
  Buf.fromSlice(
    [
      0.0f32 - 0.8f32,
      0.0f32 - 0.8f32,
      0.0f32,
      1.0f32,
      0.8f32,
      0.0f32 - 0.8f32,
      1.0f32,
      1.0f32,
      0.8f32,
      0.8f32,
      1.0f32,
      0.0f32,
      0.0f32 - 0.8f32,
      0.0f32 - 0.8f32,
      0.0f32,
      1.0f32,
      0.8f32,
      0.8f32,
      1.0f32,
      0.0f32,
      0.0f32 - 0.8f32,
      0.8f32,
      0.0f32,
      0.0f32
    ]
  )
}

func draw(d: Gpu.Device): Result[buffer[Byte], String] {
  val target = Gpu.createRenderTarget(d, size, size)
  val texture = match Gpu.createTexture(d, 2, 2, texels()) { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  val sampler = Gpu.createSampler(d, false)

  val vertices = Gpu.createBuffer(d, 96, Gpu.usageVertex + Gpu.usageCopyDst)
  Gpu.writeFloats(d, vertices, 0, quadVertices())
  val tint = Gpu.createBuffer(d, 16, Gpu.usageUniform + Gpu.usageCopyDst)
  Gpu.writeFloats(d, tint, 0, Buf.fromSlice([1.0f32, 1.0f32, 1.0f32, 1.0f32]))

  val attributes: List[Gpu.VertexAttribute] = newList()
  attributes.add(Gpu.VertexAttribute(format = Gpu.vertexFloat32x2, offset = 0, location = 0))
  attributes.add(Gpu.VertexAttribute(format = Gpu.vertexFloat32x2, offset = 8, location = 1))
  val layouts: List[Gpu.VertexLayout] = newList()
  layouts.add(Gpu.VertexLayout(stride = 16, attributes = attributes))
  val pipeline = match Gpu.createRenderPipeline(d, shader, "vs", "fs", layouts, Gpu.formatRgba8, false) {
    case Ok(p) -> p
    case Err(e) -> return Err(error = e)
  }

  val bindings: List[Gpu.Binding] = newList()
  bindings.add(BufferBinding(buffer = tint))
  bindings.add(TextureBinding(texture = texture))
  bindings.add(SamplerBinding(sampler = sampler))
  val group = match Gpu.createRenderBindGroup(d, pipeline, bindings) {
    case Ok(g) -> g
    case Err(e) -> return Err(error = e)
  }

  val buffers: List[Gpu.Buffer] = newList()
  buffers.add(vertices)
  val draws: List[Gpu.Draw] = newList()
  draws.add(
    Gpu.Draw(
      pipeline = pipeline,
      bindGroup = Some(value = group),
      vertexBuffers = buffers,
      vertexCount = 6,
      instanceCount = 1,
      firstInstance = 0,
      scissor = None
    )
  )
  match Gpu.render(d, target, 0.0, 0.0, 0.0, 1.0, draws) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  val pixels = Gpu.readPixels(d, target)
  Gpu.releaseBindGroup(group)
  Gpu.releaseRenderPipeline(pipeline)
  Gpu.releaseBuffer(tint)
  Gpu.releaseBuffer(vertices)
  Gpu.releaseSampler(sampler)
  Gpu.releaseTexture(texture)
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
  if args.length == 0 {
    return fail("usage: quad [--update] <golden.rgba>")
  }
  val path = args[args.length - 1]
  val update = args.length >= 2 and args[args.length - 2] == "--update"
  val pixels = match draw(d) { case Ok(b) -> b; case Err(e) -> return fail(e) }
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
