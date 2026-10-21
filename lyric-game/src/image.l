//! image.l - Game.Image: PNG decoding to straight-alpha RGBA8 (docs/67 G7).
//!
//! Reads every PNG colour type (grey, truecolour, palette, grey+alpha, truecolour+alpha) at every
//! legal bit depth (1, 2, 4, 8, 16), with `tRNS` transparency, and both interlace methods.  Chunk
//! CRCs are checked.  The result is the layout `Draw.createImage` takes: `width * height * 4`
//! bytes, top row first.  A malformed file is an `Err` naming the fault.
package Game.Image

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Game.Inflate

/// A decoded image.
pub record Image {
  width: Int
  height: Int
  pixels: buffer[Byte]
}

record Header {
  width: Int
  height: Int
  depth: Int
  colorType: Int
  interlace: Int
}

func be32(d: slice[Byte], at: Int): Long {
  d[at].toLong().shl(24).or(d[at + 1].toLong().shl(16)).or(d[at + 2].toLong().shl(8)).or(d[at + 3].toLong())
}

func crcTable(): buffer[Long] {
  var t = Buf.filled(256, 0i64)
  var n = 0
  while n < 256 {
    var c = n.toLong()
    var k = 0
    while k < 8 {
      if c.and(1i64) != 0i64 {
        c = 0xEDB88320i64.xor(c.shr(1).and(0x7FFFFFFFi64))
      } else {
        c = c.shr(1).and(0x7FFFFFFFi64)
      }
      k = k + 1
    }
    t[n] = c
    n = n + 1
  }
  t
}

/// The CRC-32 of `d[from ..< to]`, as PNG chunks use it.
pub func crc32(d: in slice[Byte], from: in Int, to: in Int): Long {
  val table = crcTable()
  var c = 0xFFFFFFFFi64
  var i = from
  while i < to {
    c = table[c.xor(d[i].toLong()).and(255i64).toInt()].xor(c.shr(8).and(0x00FFFFFFi64))
    i = i + 1
  }
  c.xor(0xFFFFFFFFi64)
}

func channelsOf(colorType: Int): Int {
  if colorType == 0 or colorType == 3 {
    1
  } else if colorType == 2 {
    3
  } else if colorType == 4 {
    2
  } else {
    4
  }
}

func validDepth(colorType: Int, depth: Int): Bool {
  if colorType == 0 {
    depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16
  } else if colorType == 3 {
    depth == 1 or depth == 2 or depth == 4 or depth == 8
  } else if colorType == 2 or colorType == 4 or colorType == 6 {
    depth == 8 or depth == 16
  } else {
    false
  }
}

func paeth(a: Int, b: Int, c: Int): Int {
  val p = a + b - c
  val pa = if p > a { p - a } else { a - p }
  val pb = if p > b { p - b } else { b - p }
  val pc = if p > c { p - c } else { c - p }
  if pa <= pb and pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

func sampleAt(raw: buffer[Byte], rowStart: Int, index: Int, depth: Int): Int {
  if depth == 8 {
    raw[rowStart + index].toInt()
  } else if depth == 16 {
    raw[rowStart + index * 2].toInt().shl(8).or(raw[rowStart + index * 2 + 1].toInt())
  } else {
    val bit = index * depth
    val b = raw[rowStart + bit / 8].toInt()
    val shift = 8 - depth - bit % 8
    b.shr(shift).and(1.shl(depth) - 1)
  }
}

func to8(v: Int, depth: Int): Int {
  if depth == 8 {
    v
  } else if depth == 16 {
    v.shr(8)
  } else {
    v * 255 / (1.shl(depth) - 1)
  }
}

/// Decodes a PNG file.
pub func decodePng(file: in slice[Byte]): Result[Image, String] {
  if file.length < 8 or file[0] != 137u8 or file[1] != 80u8 or file[2] != 78u8 or file[3] != 71u8 or file[4] != 13u8 or
      file[5] != 10u8 or
      file[6] != 26u8 or
      file[7] != 10u8 {
    return Err(error = "png: bad signature")
  }
  var header: Option[Header] = None
  val idat: List[Byte] = newList()
  val palette: List[Int] = newList()
  var trns: List[Int] = newList()
  var pos = 8
  var seenEnd = false
  while pos + 12 <= file.length and not seenEnd {
    val len = be32(file, pos).toInt()
    if len < 0 or pos + 12 + len > file.length {
      return Err(error = "png: truncated chunk")
    }
    val kind = file[pos + 4].toInt().shl(24).or(file[pos + 5].toInt().shl(16)).or(file[pos + 6].toInt().shl(8)).or(file[pos + 7].toInt())
    if crc32(file, pos + 4, pos + 8 + len) != be32(file, pos + 8 + len) {
      return Err(error = "png: chunk CRC mismatch")
    }
    val body = pos + 8
    if kind == 0x49484452 {
      if len != 13 {
        return Err(error = "png: bad IHDR")
      }
      header = Some(
        value = Header(
          width = be32(file, body).toInt(),
          height = be32(file, body + 4).toInt(),
          depth = file[body + 8].toInt(),
          colorType = file[body + 9].toInt(),
          interlace = file[body + 12].toInt()
        )
      )
    } else if kind == 0x504C5445 {
      var i = 0
      while i + 2 < len {
        palette.add(file[body + i].toInt())
        palette.add(file[body + i + 1].toInt())
        palette.add(file[body + i + 2].toInt())
        i = i + 3
      }
    } else if kind == 0x74524E53 {
      val t: List[Int] = newList()
      var i = 0
      while i < len {
        t.add(file[body + i].toInt())
        i = i + 1
      }
      trns = t
    } else if kind == 0x49444154 {
      var i = 0
      while i < len {
        idat.add(file[body + i])
        i = i + 1
      }
    } else if kind == 0x49454E44 {
      seenEnd = true
    }
    pos = pos + 12 + len
  }
  val h = match header {
    case Some(h) -> h
    case None -> return Err(error = "png: no IHDR chunk")
  }
  if h.width <= 0 or h.height <= 0 or h.width > 65536 or h.height > 65536 {
    return Err(error = "png: unsupported dimensions " + h.width.toString() + "x" + h.height.toString())
  }
  if not validDepth(h.colorType, h.depth) {
    return Err(error = "png: invalid bit depth " + h.depth.toString() + " for colour type " + h.colorType.toString())
  }
  if h.interlace != 0 and h.interlace != 1 {
    return Err(error = "png: unknown interlace method")
  }
  if h.colorType == 3 and palette.count == 0 {
    return Err(error = "png: palette image without a PLTE chunk")
  }
  val raw = match zlibDecompress(idat.toArray()) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "png: " + e)
  }
  decodePixels(h, raw, palette, trns)
}

func decodePixels(h: Header, rawIn: buffer[Byte], palette: List[Int], trns: List[Int]): Result[Image, String] {
  var raw = rawIn
  val channels = channelsOf(h.colorType)
  val bitsPerPixel = channels * h.depth
  val bpp = if (bitsPerPixel + 7) / 8 > 1 { (bitsPerPixel + 7) / 8 } else { 1 }
  var pixelsOut = Buf.filled(h.width * h.height * 4, 0u8)
  val passX = if h.interlace == 1 { [0, 4, 0, 2, 0, 1, 0] } else { [0] }
  val passY = if h.interlace == 1 { [0, 0, 4, 0, 2, 0, 1] } else { [0] }
  val stepX = if h.interlace == 1 { [8, 8, 4, 4, 2, 2, 1] } else { [1] }
  val stepY = if h.interlace == 1 { [8, 8, 8, 4, 4, 2, 2] } else { [1] }
  var pos = 0
  var pass = 0
  while pass < passX.length {
    val x0 = passX[pass]
    val y0 = passY[pass]
    val dx = stepX[pass]
    val dy = stepY[pass]
    val pw = (h.width - x0 + dx - 1) / dx
    val ph = (h.height - y0 + dy - 1) / dy
    if pw > 0 and ph > 0 {
      val stride = (pw * bitsPerPixel + 7) / 8
      if pos + ph * (stride + 1) > raw.length {
        return Err(error = "png: image data is shorter than the header says")
      }
      var row = 0
      while row < ph {
        val filter = raw[pos].toInt()
        val start = pos + 1
        val prior = start - (stride + 1)
        var i = 0
        while i < stride {
          val left = if i >= bpp { raw[start + i - bpp].toInt() } else { 0 }
          val up = if row > 0 { raw[prior + i].toInt() } else { 0 }
          val upLeft = if row > 0 and i >= bpp { raw[prior + i - bpp].toInt() } else { 0 }
          val x = raw[start + i].toInt()
          val predicted = if filter == 0 {
            0
          } else if filter == 1 {
            left
          } else if filter == 2 {
            up
          } else if filter == 3 {
            (left + up) / 2
          } else if filter == 4 {
            paeth(left, up, upLeft)
          } else {
            return Err(error = "png: unknown filter type " + filter.toString())
          }
          raw[start + i] = ((x + predicted) % 256).toByte()
          i = i + 1
        }
        var px = 0
        while px < pw {
          var r = 0
          var g = 0
          var b = 0
          var a = 255
          if h.colorType == 0 {
            val v = sampleAt(raw, start, px, h.depth)
            r = to8(v, h.depth)
            g = r
            b = r
            if trns.count >= 2 and v == trns[0].shl(8).or(trns[1]) {
              a = 0
            }
          } else if h.colorType == 2 {
            val vr = sampleAt(raw, start, px * 3, h.depth)
            val vg = sampleAt(raw, start, px * 3 + 1, h.depth)
            val vb = sampleAt(raw, start, px * 3 + 2, h.depth)
            r = to8(vr, h.depth)
            g = to8(vg, h.depth)
            b = to8(vb, h.depth)
            if trns.count >= 6 and vr == trns[0].shl(8).or(trns[1]) and vg == trns[2].shl(8).or(trns[3]) and
                vb == trns[4].shl(8).or(trns[5]) {
              a = 0
            }
          } else if h.colorType == 3 {
            val idx = sampleAt(raw, start, px, h.depth)
            if idx * 3 + 2 >= palette.count {
              return Err(error = "png: palette index " + idx.toString() + " is pixelsOut of range")
            }
            r = palette[idx * 3]
            g = palette[idx * 3 + 1]
            b = palette[idx * 3 + 2]
            if idx < trns.count {
              a = trns[idx]
            }
          } else if h.colorType == 4 {
            r = to8(sampleAt(raw, start, px * 2, h.depth), h.depth)
            g = r
            b = r
            a = to8(sampleAt(raw, start, px * 2 + 1, h.depth), h.depth)
          } else {
            r = to8(sampleAt(raw, start, px * 4, h.depth), h.depth)
            g = to8(sampleAt(raw, start, px * 4 + 1, h.depth), h.depth)
            b = to8(sampleAt(raw, start, px * 4 + 2, h.depth), h.depth)
            a = to8(sampleAt(raw, start, px * 4 + 3, h.depth), h.depth)
          }
          val o = ((y0 + row * dy) * h.width + x0 + px * dx) * 4
          pixelsOut[o] = r.toByte()
          pixelsOut[o + 1] = g.toByte()
          pixelsOut[o + 2] = b.toByte()
          pixelsOut[o + 3] = a.toByte()
          px = px + 1
        }
        pos = pos + stride + 1
        row = row + 1
      }
    }
    pass = pass + 1
  }
  Ok(value = Image(width = h.width, height = h.height, pixels = pixelsOut))
}
