//! layers: indexed draws into a depth-tested target, and a mipmapped texture, compared with a
//! golden image.
//!   - a near red square is drawn before a far green one that overlaps it; the depth test keeps
//!     the red square in front where they overlap;
//!   - a blue square wound clockwise is culled as a back face;
//!   - a 64x64 texture of one white column in four, mipmapped, is drawn on a 16x16 square with a
//!     linear sampler, so it is sampled from the 16x16 level and shows a uniform dark grey (64).
//! Each square is four vertices and six 32-bit indices.  The program checks those four facts at
//! sample pixels and then compares the whole image with the golden one.
//!   layers <golden.rgba>            compare; exit 1 when a check fails or too many pixels differ
//!   layers --update <golden.rgba>   write the rendered pixels as the new golden
//! See `triangle` for the tolerance.
package Gpu.Examples.Layers

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

val colorShader: String = "struct VOut { @builtin(position) pos: vec4<f32>, @location(0) color: vec3<f32> }\n@vertex\nfn vs(@location(0) pos: vec3<f32>, @location(1) color: vec3<f32>) -> VOut {\n  var out: VOut;\n  out.pos = vec4<f32>(pos, 1.0);\n  out.color = color;\n  return out;\n}\n@fragment\nfn fs(in: VOut) -> @location(0) vec4<f32> {\n  return vec4<f32>(in.color, 1.0);\n}\n"

val textureShader: String = "@group(0) @binding(0) var tex: texture_2d<f32>;\n@group(0) @binding(1) var samp: sampler;\nstruct VOut { @builtin(position) pos: vec4<f32>, @location(0) uv: vec2<f32> }\n@vertex\nfn vs(@location(0) pos: vec3<f32>, @location(1) uv: vec2<f32>) -> VOut {\n  var out: VOut;\n  out.pos = vec4<f32>(pos, 1.0);\n  out.uv = uv;\n  return out;\n}\n@fragment\nfn fs(in: VOut) -> @location(0) vec4<f32> {\n  return textureSample(tex, samp, in.uv);\n}\n"

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func channelDiff(a: Byte, b: Byte): Int {
  val x = a.toInt()
  val y = b.toInt()
  if x > y then x - y else y - x
}

// Four corners of the square from (x0, y0) to (x1, y1) at depth z, each followed by three
// attributes: the colour, or u, v and an unused 0.
func corners(acc: List[Float], x0: Float, y0: Float, x1: Float, y1: Float, z: Float, a: Float, b: Float, c: Float): Unit {
  acc.add(x0)
  acc.add(y0)
  acc.add(z)
  acc.add(a)
  acc.add(b)
  acc.add(c)
  acc.add(x1)
  acc.add(y0)
  acc.add(z)
  acc.add(a)
  acc.add(b)
  acc.add(c)
  acc.add(x1)
  acc.add(y1)
  acc.add(z)
  acc.add(a)
  acc.add(b)
  acc.add(c)
  acc.add(x0)
  acc.add(y1)
  acc.add(z)
  acc.add(a)
  acc.add(b)
  acc.add(c)
}

// Two triangles over the square whose corners start at `base`, counter-clockwise (front-facing)
// or clockwise.
func squareIndices(acc: List[Int], base: Int, front: Bool): Unit {
  val second = if front then 1 else 2
  val third = if front then 2 else 1
  acc.add(base)
  acc.add(base + second)
  acc.add(base + third)
  acc.add(base)
  acc.add(base + second + 1)
  acc.add(base + third + 1)
}

// One white column in every four, the rest black: its mip levels average to a quarter of white
// (64), while sampling the full-size image four times smaller lands between two black columns.
func stripes(): buffer[Byte] {
  var pixels = Buf.filled(size * size * 4, 255u8)
  var y = 0
  while y < size {
    var x = 0
    while x < size {
      if x % 4 != 0 {
        val p = (y * size + x) * 4
        pixels[p] = 0u8
        pixels[p + 1] = 0u8
        pixels[p + 2] = 0u8
      }
      x = x + 1
    }
    y = y + 1
  }
  pixels
}

func floats(values: List[Float]): buffer[Float] {
  var acc = Buf.filled(values.count, 0.0f32)
  var i = 0
  while i < values.count {
    acc[i] = values[i]
    i = i + 1
  }
  acc
}

func ints(values: List[Int]): buffer[Int] {
  var acc = Buf.filled(values.count, 0)
  var i = 0
  while i < values.count {
    acc[i] = values[i]
    i = i + 1
  }
  acc
}

func upload(d: Gpu.Device, data: buffer[Float], usage: Long): Result[Gpu.Buffer, String] {
  val b = match Gpu.createBuffer(d, data.length.toLong() * 4, usage + Gpu.usageCopyDst) {
    case Ok(x) -> x
    case Err(e) -> return Err(error = e)
  }
  match Gpu.writeFloats(d, b, 0, data) {
    case Ok(_) -> Ok(value = b)
    case Err(e) -> {
      Gpu.releaseBuffer(b)
      Err(error = e)
    }
  }
}

func uploadIndices(d: Gpu.Device, data: buffer[Int]): Result[Gpu.Buffer, String] {
  val b = match Gpu.createBuffer(d, data.length.toLong() * 4, Gpu.usageIndex + Gpu.usageCopyDst) {
    case Ok(x) -> x
    case Err(e) -> return Err(error = e)
  }
  match Gpu.writeInts(d, b, 0, data) {
    case Ok(_) -> Ok(value = b)
    case Err(e) -> {
      Gpu.releaseBuffer(b)
      Err(error = e)
    }
  }
}

func layout(): List[Gpu.VertexLayout] {
  val attributes: List[Gpu.VertexAttribute] = newList()
  attributes.add(Gpu.VertexAttribute(format = Gpu.vertexFloat32x3, offset = 0, location = 0))
  attributes.add(Gpu.VertexAttribute(format = Gpu.vertexFloat32x3, offset = 12, location = 1))
  val layouts: List[Gpu.VertexLayout] = newList()
  layouts.add(Gpu.VertexLayout(stride = 24, attributes = attributes))
  layouts
}

func pipeline(d: Gpu.Device, source: String): Result[Gpu.RenderPipeline, String] {
  Gpu.createRenderPipelineFrom(
    d,
    Gpu.RenderPipelineDesc(
      source = source,
      vertexEntry = "vs",
      fragmentEntry = "fs",
      layouts = layout(),
      format = Gpu.formatRgba8,
      blend = false,
      depthTest = true,
      cullBack = true
    )
  )
}

func draw(d: Gpu.Device): Result[buffer[Byte], String] {
  val target = match Gpu.createRenderTarget(d, size, size) { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  val depth = match Gpu.createDepthTarget(d, size, size) { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  val flat = match pipeline(d, colorShader) { case Ok(p) -> p; case Err(e) -> return Err(error = e) }
  val textured = match pipeline(d, textureShader) { case Ok(p) -> p; case Err(e) -> return Err(error = e) }
  val texture = match Gpu.createMipmappedTexture(d, size, size, stripes()) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = e)
  }
  val sampler = match Gpu.createSampler(d, true) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  val bindings: List[Gpu.Binding] = newList()
  bindings.add(TextureBinding(texture = texture))
  bindings.add(SamplerBinding(sampler = sampler))
  val group = match Gpu.createRenderBindGroup(d, textured, bindings) {
    case Ok(g) -> g
    case Err(e) -> return Err(error = e)
  }

  // Squares 0 (near, red), 1 (far, green) and 2 (blue, clockwise) share one vertex and one
  // index buffer; square 3 (the stripes) has its own, with u, v in the colour slots.
  val colored: List[Float] = newList()
  corners(colored, 0.0f32 - 0.7f32, 0.0f32 - 0.7f32, 0.3, 0.3, 0.2, 1.0, 0.0, 0.0)
  corners(colored, 0.0f32 - 0.3f32, 0.0f32 - 0.3f32, 0.7, 0.7, 0.6, 0.0, 1.0, 0.0)
  corners(colored, 0.4, 0.0f32 - 0.9f32, 0.9, 0.0f32 - 0.4f32, 0.1, 0.0, 0.0, 1.0)
  val coloredIndices: List[Int] = newList()
  squareIndices(coloredIndices, 0, true)
  squareIndices(coloredIndices, 4, true)
  squareIndices(coloredIndices, 8, false)
  val quad: List[Float] = newList()
  quad.add(0.0f32 - 1.0f32)
  quad.add(0.5)
  quad.add(0.9)
  quad.add(0.0)
  quad.add(1.0)
  quad.add(0.0)
  quad.add(0.0f32 - 0.5f32)
  quad.add(0.5)
  quad.add(0.9)
  quad.add(1.0)
  quad.add(1.0)
  quad.add(0.0)
  quad.add(0.0f32 - 0.5f32)
  quad.add(1.0)
  quad.add(0.9)
  quad.add(1.0)
  quad.add(0.0)
  quad.add(0.0)
  quad.add(0.0f32 - 1.0f32)
  quad.add(1.0)
  quad.add(0.9)
  quad.add(0.0)
  quad.add(0.0)
  quad.add(0.0)
  val quadIndices: List[Int] = newList()
  squareIndices(quadIndices, 0, true)

  val vertices = match upload(d, floats(colored), Gpu.usageVertex) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = e)
  }
  val indices = match uploadIndices(d, ints(coloredIndices)) { case Ok(b) -> b; case Err(e) -> return Err(error = e) }
  val quadVertices = match upload(d, floats(quad), Gpu.usageVertex) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = e)
  }
  val quadIndexBuffer = match uploadIndices(d, ints(quadIndices)) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = e)
  }

  val coloredBuffers: List[Gpu.Buffer] = newList()
  coloredBuffers.add(vertices)
  val quadBuffers: List[Gpu.Buffer] = newList()
  quadBuffers.add(quadVertices)
  val draws: List[Gpu.Draw] = newList()
  draws.add(
    Gpu.Draw(
      pipeline = flat,
      bindGroup = None,
      vertexBuffers = coloredBuffers,
      vertexCount = 0,
      instanceCount = 1,
      firstInstance = 0,
      scissor = None,
      indices = Some(value = Gpu.Indices(buffer = indices, count = coloredIndices.count))
    )
  )
  draws.add(
    Gpu.Draw(
      pipeline = textured,
      bindGroup = Some(value = group),
      vertexBuffers = quadBuffers,
      vertexCount = 0,
      instanceCount = 1,
      firstInstance = 0,
      scissor = None,
      indices = Some(value = Gpu.Indices(buffer = quadIndexBuffer, count = quadIndices.count))
    )
  )
  val rendered = Gpu.renderWithDepth(d, target, depth, 0.0, 0.0, 0.0, 1.0, draws)
  val pixels = match rendered { case Ok(_) -> Gpu.readPixels(d, target); case Err(e) -> Err(error = e) }
  Gpu.releaseBuffer(quadIndexBuffer)
  Gpu.releaseBuffer(quadVertices)
  Gpu.releaseBuffer(indices)
  Gpu.releaseBuffer(vertices)
  Gpu.releaseBindGroup(group)
  Gpu.releaseSampler(sampler)
  Gpu.releaseTexture(texture)
  Gpu.releaseRenderPipeline(textured)
  Gpu.releaseRenderPipeline(flat)
  Gpu.releaseDepthTarget(depth)
  Gpu.releaseRenderTarget(target)
  pixels
}

func pixelAt(pixels: buffer[Byte], x: Int, y: Int): String {
  val p = (y * size + x) * 4
  pixels[p].toString() + "," + pixels[p + 1].toString() + "," + pixels[p + 2].toString()
}

func isColor(pixels: buffer[Byte], x: Int, y: Int, r: Int, g: Int, b: Int): Bool {
  val p = (y * size + x) * 4
  val dr = pixels[p].toInt() - r
  val dg = pixels[p + 1].toInt() - g
  val db = pixels[p + 2].toInt() - b
  dr * dr + dg * dg + db * db < 3 * channelTolerance * channelTolerance
}

// The checks the golden image also covers, stated at sample pixels so a failure says which one.
func checkScene(pixels: buffer[Byte]): Int {
  var failures = 0
  if not isColor(pixels, 32, 32, 255, 0, 0) {
    Console.println("depth: the near square is not in front where they overlap (" + pixelAt(pixels, 32, 32) + ")")
    failures = failures + 1
  }
  if not isColor(pixels, 48, 16, 0, 255, 0) or not isColor(pixels, 16, 48, 255, 0, 0) {
    Console.println(
      "indexed draw: a square is missing (" + pixelAt(pixels, 48, 16) + " / " + pixelAt(pixels, 16, 48) + ")"
    )
    failures = failures + 1
  }
  if not isColor(pixels, 52, 52, 0, 0, 0) {
    Console.println("culling: the clockwise square was drawn (" + pixelAt(pixels, 52, 52) + ")")
    failures = failures + 1
  }
  var grey = true
  var y = 3
  while y < 13 {
    var x = 3
    while x < 13 {
      val p = (y * size + x) * 4
      val v = pixels[p].toInt()
      if v < 44 or v > 84 {
        grey = false
      }
      x = x + 1
    }
    y = y + 1
  }
  if not grey {
    Console.println("mipmaps: the minified stripes are not a uniform grey (" + pixelAt(pixels, 8, 8) + ")")
    failures = failures + 1
  }
  if failures == 0 {
    Console.println("depth, indexed draws, culling and mipmaps checked")
  }
  failures
}

func compare(pixels: buffer[Byte], golden: slice[Byte]): Int {
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
    return fail("usage: layers [--update] <golden.rgba>")
  }
  val path = args[args.length - 1]
  val update = args.length >= 2 and args[args.length - 2] == "--update"
  val pixels = match draw(d) { case Ok(b) -> b; case Err(e) -> return fail(e) }
  if checkScene(pixels) != 0 {
    return fail("the scene is wrong")
  }
  if update {
    return match File.writeBytes(path, Buf.toSlice(pixels)) {
      case Ok(_) -> {
        Console.println("wrote " + path)
        0
      }
      case Err(e) -> fail("cannot write " + path + ": " + IOError.message(e))
    }
  }
  match File.readBytes(path) {
    case Ok(golden) -> compare(pixels, golden)
    case Err(e) -> fail("cannot read " + path + ": " + IOError.message(e))
  }
}

func main(): Int {
  val args = Environment.args()
  val body: (Gpu.Device) -> Int = { d: Gpu.Device -> run(d, args) }
  match Gpu.withDevice(body) {
    case Ok(code) -> code
    case Err(e) -> fail(e)
  }
}
