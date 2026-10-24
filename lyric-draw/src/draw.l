//! draw.l - Draw: an immediate-mode 2D renderer on `lyric-gpu` for `--target native`
//! (docs/67 phase G6).
//!
//! A `Painter` collects a frame's drawing as instances of one pipeline, in order: filled,
//! stroked and rounded rectangles and soft shadows drawn as signed-distance quads with a one
//! pixel antialiased edge, images, and text runs from `lyric-text` drawn from a glyph atlas.
//! `finish` uploads the instances, a changed atlas, and the viewport, and issues one instanced
//! draw per batch of consecutive instances that share a texture and a clip rectangle.
//!
//! Coordinates are logical pixels with the origin at the top-left and y growing downward; a
//! painter drawing into a high-DPI target is given the target's scale (`setScale`) and multiplies
//! every coordinate, size, radius and blur by it, so callers lay out once for any display.  Colours are
//! straight (non-premultiplied) RGBA in 0 to 1 and are composited with premultiplied alpha.
//! Clips are rectangles in whole pixels (the clip stack's intersection), applied as scissors.
@io
package Draw

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Math as M
import Gpu as G
import Text

/// A straight RGBA colour, each channel 0 to 1.
pub record Color {
  r: Float
  g: Float
  b: Float
  a: Float
}

pub func rgba(r: Float, g: Float, b: Float, a: Float): Color {
  Color(r = r, g = g, b = b, a = a)
}

pub func rgb(r: Float, g: Float, b: Float): Color {
  Color(r = r, g = g, b = b, a = 1.0f32)
}

/// A rectangle in pixels from its top-left corner.
pub record Rect {
  x: Float
  y: Float
  width: Float
  height: Float
}

/// An image to draw with `drawImage`.
pub record Image {
  texture: G.Texture
  width: Int
  height: Int
  pixelArt: Bool
}

ref record Batch {
  texture: G.Texture
  crisp: Bool
  first: Int
  var count: Int
  scissor: Option[G.Scissor]
}

/// The renderer: its pipeline, textures and buffers, and the frame being collected.
pub ref record Painter {
  device: G.Device
  pipeline: G.RenderPipeline
  sampler: G.Sampler
  nearest: G.Sampler
  white: G.Texture
  atlas: Text.Atlas
  atlasTexture: G.Texture
  view: G.Buffer
  var instances: G.Buffer
  var capacity: Int
  var atlasUploaded: Int
  var width: Int
  var height: Int
  var scale: Float
  var data: List[Float]
  var batches: List[Batch]
  var clips: List[G.Scissor]
}

val floatsPerInstance: Int = 16

val atlasSize: Int = 1024

val initialCapacity: Int = 1024

val shapeKindFill: Float = 0.0f32

val shapeKindStroke: Float = 1.0f32

val shapeKindShadow: Float = 2.0f32

val shapeKindTexture: Float = 3.0f32

val shader: String = "struct View { size: vec2<f32>, pad: vec2<f32> }\n" + "struct Inst { rect: vec4<f32>, color: vec4<f32>, params: vec4<f32>, uv: vec4<f32> }\n" + "@group(0) @binding(0) var<uniform> view: View;\n" + "@group(0) @binding(1) var<storage, read> insts: array<Inst>;\n" + "@group(0) @binding(2) var tex: texture_2d<f32>;\n" + "@group(0) @binding(3) var samp: sampler;\n" + "struct VOut {\n" + "  @builtin(position) pos: vec4<f32>,\n" + "  @location(0) local: vec2<f32>,\n" + "  @location(1) @interpolate(flat) idx: u32,\n" + "  @location(2) uv: vec2<f32>,\n" + "}\n" + "@vertex\n" + "fn vs(@builtin(vertex_index) vi: u32, @builtin(instance_index) ii: u32) -> VOut {\n" + "  let inst = insts[ii];\n" + "  var corners = array<vec2<f32>, 6>(vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0));\n" + "  let c = corners[vi];\n" + "  var margin = 1.0;\n" + "  if (inst.params.x == 2.0) { margin = inst.params.z * 3.0 + 1.0; }\n" + "  if (inst.params.x == 3.0) { margin = 0.0; }\n" + "  let lo = inst.rect.xy - vec2<f32>(margin, margin);\n" + "  let size = inst.rect.zw + vec2<f32>(2.0 * margin, 2.0 * margin);\n" + "  let p = lo + c * size;\n" + "  var out: VOut;\n" + "  out.pos = vec4<f32>(p.x / view.size.x * 2.0 - 1.0, 1.0 - p.y / view.size.y * 2.0, 0.0, 1.0);\n" + "  out.local = p - (inst.rect.xy + inst.rect.zw * 0.5);\n" + "  out.idx = ii;\n" + "  out.uv = mix(inst.uv.xy, inst.uv.zw, c);\n" + "  return out;\n" + "}\n" + "@fragment\n" + "fn fs(in: VOut) -> @location(0) vec4<f32> {\n" + "  let inst = insts[in.idx];\n" + "  let kind = inst.params.x;\n" + "  let sampled = textureSampleLevel(tex, samp, in.uv, 0.0);\n" + "  if (kind == 3.0) { return inst.color * sampled; }\n" + "  let half = inst.rect.zw * 0.5;\n" + "  let r = min(inst.params.y, min(half.x, half.y));\n" + "  let q = abs(in.local) - half + vec2<f32>(r, r);\n" + "  let d = length(max(q, vec2<f32>(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - r;\n" + "  var cov = clamp(0.5 - d, 0.0, 1.0);\n" + "  if (kind == 1.0) {\n" + "    let w = inst.params.z;\n" + "    cov = clamp(0.5 - (abs(d + w * 0.5) - w * 0.5), 0.0, 1.0);\n" + "  }\n" + "  if (kind == 2.0) {\n" + "    let s = max(inst.params.z, 0.001);\n" + "    cov = 1.0 - smoothstep(-s, s, d);\n" + "  }\n" + "  return inst.color * cov;\n" + "}\n"

/// A painter drawing into targets of `format` (`G.formatRgba8` offscreen, a surface's format
/// for its frames).  Release it with `releasePainter`.
pub func newPainter(d: G.Device, format: Int): Result[Painter, String] {
  val noLayouts: List[G.VertexLayout] = newList()
  val pipeline = match G.createRenderPipeline(d, shader, "vs", "fs", noLayouts, format, true) {
    case Ok(p) -> p
    case Err(e) -> return Err(error = e)
  }
  val sampler = G.createSampler(d, true)
  val nearest = G.createSampler(d, false)
  val white = match G.createTexture(d, 1, 1, Buf.fromSlice([255u8, 255u8, 255u8, 255u8])) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = e)
  }
  val atlas = Text.newAtlas(atlasSize, atlasSize)
  val atlasTexture = match G.createTexture(d, atlasSize, atlasSize, Buf.filled(atlasSize * atlasSize * 4, 0u8)) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = e)
  }
  val view = G.createBuffer(d, 16, G.usageUniform + G.usageCopyDst)
  val instances = G.createBuffer(d, (initialCapacity * floatsPerInstance * 4).toLong(), G.usageStorage + G.usageCopyDst)
  Ok(
    value = Painter(
      device = d,
      pipeline = pipeline,
      sampler = sampler,
      nearest = nearest,
      white = white,
      atlas = atlas,
      atlasTexture = atlasTexture,
      view = view,
      instances = instances,
      capacity = initialCapacity,
      atlasUploaded = 0,
      width = 0,
      height = 0,
      scale = 1.0f32,
      data = newList(),
      batches = newList(),
      clips = newList()
    )
  )
}

pub func releasePainter(p: Painter): Unit {
  G.releaseRenderPipeline(p.pipeline)
  G.releaseSampler(p.sampler)
  G.releaseSampler(p.nearest)
  G.releaseTexture(p.white)
  G.releaseTexture(p.atlasTexture)
  G.releaseBuffer(p.view)
  G.releaseBuffer(p.instances)
}

/// Sets how many target pixels one logical pixel covers (1 by default).  Every coordinate,
/// length, corner radius, line width and blur given to the drawing functions after this is
/// multiplied by it; the target size given to `beginFrame` stays in target pixels.  Text is
/// positioned and wrapped in logical pixels too, but is rasterised from the fonts it is given, so
/// open them at the scaled size.
pub func setScale(p: Painter, scale: Float): Unit
  requires: scale > 0.0f32
{
  p.scale = scale
}

/// Starts a frame for a target of `width` by `height` pixels, discarding anything collected.
pub func beginFrame(p: Painter, width: Int, height: Int): Unit {
  p.width = width
  p.height = height
  p.data = newList()
  p.batches = newList()
  p.clips = newList()
}

/// An image from straight-alpha RGBA8 pixels (`width * height * 4` bytes, top row first).
/// `pixelArt` samples it with nearest-neighbour filtering instead of bilinear, so scaled-up
/// pixels stay sharp.
pub func createImage(p: Painter, width: Int, height: Int, pixels: buffer[Byte], pixelArt: Bool): Result[Image, String] {
  if pixels.length != width * height * 4 {
    return Err(
      error = "createImage: " + width.toString() + "x" + height.toString() + " needs " +
        (width * height * 4).toString() +
        " bytes"
    )
  }
  var premultiplied = Buf.filled(pixels.length, 0u8)
  var i = 0
  while i < pixels.length {
    val a = pixels[i + 3].toInt()
    premultiplied[i] = ((pixels[i].toInt() * a + 127) / 255).toByte()
    premultiplied[i + 1] = ((pixels[i + 1].toInt() * a + 127) / 255).toByte()
    premultiplied[i + 2] = ((pixels[i + 2].toInt() * a + 127) / 255).toByte()
    premultiplied[i + 3] = a.toByte()
    i = i + 4
  }
  match G.createTexture(p.device, width, height, premultiplied) {
    case Ok(t) -> Ok(value = Image(texture = t, width = width, height = height, pixelArt = pixelArt))
    case Err(e) -> Err(error = e)
  }
}

pub func releaseImage(image: Image): Unit {
  G.releaseTexture(image.texture)
}

// ---------------------------------------------------------------------------
// Clipping.
// ---------------------------------------------------------------------------
func floorInt(v: Float): Int {
  M.floor(v.toDouble()).toInt()
}

func ceilInt(v: Float): Int {
  M.ceiling(v.toDouble()).toInt()
}

func currentClip(p: Painter): Option[G.Scissor] {
  if p.clips.count == 0 {
    None
  } else {
    Some(value = p.clips[p.clips.count - 1])
  }
}

/// Restricts later drawing to the intersection of `r` (rounded outward to whole pixels) and the
/// clips already pushed.  Pair with `popClip`.
pub func pushClip(p: Painter, r: Rect): Unit {
  val k = p.scale
  var x0 = floorInt(r.x * k)
  var y0 = floorInt(r.y * k)
  var x1 = ceilInt((r.x + r.width) * k)
  var y1 = ceilInt((r.y + r.height) * k)
  match currentClip(p) {
    case Some(c) -> {
      if c.x > x0 {
        x0 = c.x
      }
      if c.y > y0 {
        y0 = c.y
      }
      if c.x + c.width < x1 {
        x1 = c.x + c.width
      }
      if c.y + c.height < y1 {
        y1 = c.y + c.height
      }
    }
    case None -> ()
  }
  if x0 < 0 {
    x0 = 0
  }
  if y0 < 0 {
    y0 = 0
  }
  if x1 > p.width {
    x1 = p.width
  }
  if y1 > p.height {
    y1 = p.height
  }
  val w = if x1 > x0 { x1 - x0 } else { 0 }
  val h = if y1 > y0 { y1 - y0 } else { 0 }
  p.clips.add(G.Scissor(x = x0, y = y0, width = w, height = h))
}

pub func popClip(p: Painter): Unit
  requires: p.clips.count > 0
{
  val kept: List[G.Scissor] = newList()
  var i = 0
  while i < p.clips.count - 1 {
    kept.add(p.clips[i])
    i = i + 1
  }
  p.clips = kept
}

func sameScissor(a: Option[G.Scissor], b: Option[G.Scissor]): Bool {
  match a {
    case None -> match b { case None -> true; case Some(_) -> false }
    case Some(x) -> match b {
      case None -> false
      case Some(y) -> x.x == y.x and x.y == y.y and x.width == y.width and x.height == y.height
    }
  }
}

// ---------------------------------------------------------------------------
// Instances.
// ---------------------------------------------------------------------------
func addInstance(
  p: Painter,
  texture: G.Texture,
  kind: Float,
  x: Float,
  y: Float,
  w: Float,
  h: Float,
  c: Color,
  radius: Float,
  extra: Float,
  u0: Float,
  v0: Float,
  u1: Float,
  v1: Float,
  crisp: Bool,
): Unit {
  val clip = currentClip(p)
  match clip {
    case Some(s) -> if s.width == 0 or s.height == 0 { return }
    case None -> ()
  }
  val first = p.data.count / floatsPerInstance
  val open = p.batches.count > 0 and p.batches[p.batches.count - 1].texture.raw == texture.raw and
    p.batches[p.batches.count - 1].crisp == crisp and
    sameScissor(p.batches[p.batches.count - 1].scissor, clip)
  if open {
    p.batches[p.batches.count - 1].count = p.batches[p.batches.count - 1].count + 1
  } else {
    p.batches.add(Batch(texture = texture, crisp = crisp, first = first, count = 1, scissor = clip))
  }
  val d = p.data
  val k = p.scale
  d.add(x * k)
  d.add(y * k)
  d.add(w * k)
  d.add(h * k)
  d.add(c.r * c.a)
  d.add(c.g * c.a)
  d.add(c.b * c.a)
  d.add(c.a)
  d.add(kind)
  d.add(radius * k)
  d.add(if kind == shapeKindTexture { extra } else { extra * k })
  d.add(0.0f32)
  d.add(u0)
  d.add(v0)
  d.add(u1)
  d.add(v1)
}

/// A filled rectangle.
pub func fillRect(p: Painter, r: Rect, c: Color): Unit {
  addInstance(
    p,
    p.white,
    shapeKindFill,
    r.x,
    r.y,
    r.width,
    r.height,
    c,
    0.0f32,
    0.0f32,
    0.0f32,
    0.0f32,
    1.0f32,
    1.0f32,
    false
  )
}

/// A filled rectangle with corners of `radius` pixels.
pub func fillRoundedRect(p: Painter, r: Rect, radius: Float, c: Color): Unit {
  addInstance(
    p,
    p.white,
    shapeKindFill,
    r.x,
    r.y,
    r.width,
    r.height,
    c,
    radius,
    0.0f32,
    0.0f32,
    0.0f32,
    1.0f32,
    1.0f32,
    false
  )
}

/// A border `lineWidth` pixels wide, inside the rectangle's edge.
pub func strokeRoundedRect(p: Painter, r: Rect, radius: Float, lineWidth: Float, c: Color): Unit {
  addInstance(
    p,
    p.white,
    shapeKindStroke,
    r.x,
    r.y,
    r.width,
    r.height,
    c,
    radius,
    lineWidth,
    0.0f32,
    0.0f32,
    1.0f32,
    1.0f32,
    false
  )
}

/// A soft shadow of a rounded rectangle: full strength inside it, fading to nothing over
/// `blur` pixels either side of its edge.  Draw it before the shape that casts it.
pub func drawShadow(p: Painter, r: Rect, radius: Float, blur: Float, c: Color): Unit {
  addInstance(
    p,
    p.white,
    shapeKindShadow,
    r.x,
    r.y,
    r.width,
    r.height,
    c,
    radius,
    blur,
    0.0f32,
    0.0f32,
    1.0f32,
    1.0f32,
    false
  )
}

/// An image stretched over `dest`, multiplied by `tint` (white for none).
pub func drawImage(p: Painter, image: Image, dest: Rect, tint: Color): Unit {
  addInstance(
    p,
    image.texture,
    shapeKindTexture,
    dest.x,
    dest.y,
    dest.width,
    dest.height,
    tint,
    0.0f32,
    0.0f32,
    0.0f32,
    0.0f32,
    1.0f32,
    1.0f32,
    image.pixelArt
  )
}

/// The part of `image` inside `source` (in image pixels, from its top-left corner) stretched over
/// `dest`, multiplied by `tint`: one cell of a sprite sheet or atlas.
pub func drawImageRegion(p: Painter, image: Image, source: Rect, dest: Rect, tint: Color): Unit {
  val w = image.width.toFloat()
  val h = image.height.toFloat()
  addInstance(
    p,
    image.texture,
    shapeKindTexture,
    dest.x,
    dest.y,
    dest.width,
    dest.height,
    tint,
    0.0f32,
    0.0f32,
    source.x / w,
    source.y / h,
    (source.x + source.width) / w,
    (source.y + source.height) / h,
    image.pixelArt
  )
}

/// Lays `text` out with `fonts` in a column `maxWidth` logical pixels wide (no wrapping when it is not
/// positive) and draws it with its top-left corner at (`x`, `y`).  Returns the layout, whose
/// `width` and `height` size the block.  `Err` when the glyph atlas is full.
pub func drawText(
  p: Painter, fonts: List[Text.Font], text: String, x: Float, y: Float, maxWidth: Float, c: Color
): Result[Text.TextLayout, String] {
  val k = p.scale
  val layout = Text.layoutText(fonts, text, maxWidth * k)
  val size = atlasSize.toFloat()
  for g in layout.glyphs {
    val region = match Text.atlasGlyph(p.atlas, fonts[g.font], g.glyph) {
      case Ok(r) -> r
      case Err(e) -> return Err(error = e)
    }
    if region.width > 0 {
      val gx = (x * k + g.x + 0.5f32).toInt().toFloat() + region.left.toFloat()
      val gy = (y * k + g.y + 0.5f32).toInt().toFloat() - region.top.toFloat()
      addInstance(
        p,
        p.atlasTexture,
        shapeKindTexture,
        gx / k,
        gy / k,
        region.width.toFloat() / k,
        region.height.toFloat() / k,
        c,
        0.0f32,
        0.0f32,
        region.x.toFloat() / size,
        region.y.toFloat() / size,
        (region.x + region.width).toFloat() / size,
        (region.y + region.height).toFloat() / size,
        false
      )
    }
  }
  Ok(value = layout)
}

// ---------------------------------------------------------------------------
// Submitting a frame.
// ---------------------------------------------------------------------------
// The atlas holds one coverage byte per pixel; the texture holds it premultiplied in all four
// channels, so a glyph's tint times the sample is the tint times its coverage.
func uploadAtlas(p: Painter): Result[Unit, String] {
  if p.atlas.version == p.atlasUploaded {
    return Ok(value = ())
  }
  val n = atlasSize * atlasSize
  var rgba = Buf.filled(n * 4, 0u8)
  var i = 0
  while i < n {
    val v = p.atlas.pixels[i]
    rgba[i * 4] = v
    rgba[i * 4 + 1] = v
    rgba[i * 4 + 2] = v
    rgba[i * 4 + 3] = v
    i = i + 1
  }
  match G.writeTexture(p.device, p.atlasTexture, rgba) {
    case Ok(_) -> {
      p.atlasUploaded = p.atlas.version
      Ok(value = ())
    }
    case Err(e) -> Err(error = e)
  }
}

/// Clears `target` to `clear` and draws the frame collected since `beginFrame`.  The target's
/// size must be the one `beginFrame` was given.
pub func finish(p: Painter, target: G.RenderTarget, clear: Color): Result[Unit, String] {
  if target.width != p.width or target.height != p.height {
    return Err(
      error = "finish: the target is " + target.width.toString() + "x" + target.height.toString() +
        " but the frame began at " +
        p.width.toString() +
        "x" +
        p.height.toString()
    )
  }
  val noDraws: List[G.Draw] = newList()
  val count = p.data.count / floatsPerInstance
  if count == 0 {
    return G.render(p.device, target, clear.r * clear.a, clear.g * clear.a, clear.b * clear.a, clear.a, noDraws)
  }
  match uploadAtlas(p) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  if count > p.capacity {
    var next = p.capacity
    while next < count {
      next = next * 2
    }
    G.releaseBuffer(p.instances)
    p.instances = G.createBuffer(p.device, (next * floatsPerInstance * 4).toLong(), G.usageStorage + G.usageCopyDst)
    p.capacity = next
  }
  var values = Buf.filled(p.data.count, 0.0f32)
  var i = 0
  while i < p.data.count {
    values[i] = p.data[i]
    i = i + 1
  }
  G.writeFloats(p.device, p.instances, 0, values)
  var viewData = Buf.filled(4, 0.0f32)
  viewData[0] = target.width.toFloat()
  viewData[1] = target.height.toFloat()
  G.writeFloats(p.device, p.view, 0, viewData)

  val groups: Map[Long, G.BindGroup] = newMap()
  val draws: List[G.Draw] = newList()
  val noBuffers: List[G.Buffer] = newList()
  for b in p.batches {
    val groupKey = b.texture.raw * 2 + (if b.crisp { 1 } else { 0 })
    val group = match mapGet(groups, groupKey) {
      case Some(g) -> g
      case None -> {
        val bindings: List[G.Binding] = newList()
        bindings.add(G.BufferBinding(buffer = p.view))
        bindings.add(G.BufferBinding(buffer = p.instances))
        bindings.add(G.TextureBinding(texture = b.texture))
        bindings.add(G.SamplerBinding(sampler = if b.crisp { p.nearest } else { p.sampler }))
        val made = match G.createRenderBindGroup(p.device, p.pipeline, bindings) {
          case Ok(g) -> g
          case Err(e) -> {
            releaseGroups(groups)
            return Err(error = e)
          }
        }
        groups.add(groupKey, made)
        made
      }
    }
    draws.add(
      G.Draw(
        pipeline = p.pipeline,
        bindGroup = Some(value = group),
        vertexBuffers = noBuffers,
        vertexCount = 6,
        instanceCount = b.count,
        firstInstance = b.first,
        scissor = b.scissor
      )
    )
  }
  val result = G.render(p.device, target, clear.r * clear.a, clear.g * clear.a, clear.b * clear.a, clear.a, draws)
  releaseGroups(groups)
  result
}

func releaseGroups(groups: Map[Long, G.BindGroup]): Unit {
  for key in mapKeys(groups) {
    match mapGet(groups, key) {
      case Some(g) -> G.releaseBindGroup(g)
      case None -> ()
    }
  }
}
