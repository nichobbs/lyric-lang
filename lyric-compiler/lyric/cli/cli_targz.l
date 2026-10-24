package Lyric.Cli

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Parse as Parse
import Jvm.Deflate as Deflate

// ─────────────────────────────────────────────────────────────────────────────
// `.tar.gz` prebuilt archives (docs/67 §6, D232): a gzip stream (RFC 1952) over
// a POSIX tar (ustar, pax and GNU long names), read in pure Lyric on top of
// `Jvm.Deflate`.  Arithmetic stands in for bit operations so the seed compiler
// builds this file.
// ─────────────────────────────────────────────────────────────────────────────
func byteAt(data: in slice[Byte], i: in Int): Int = data[i].toInt()

func le32(data: in slice[Byte], i: in Int): Long {
  val b0 = byteAt(data, i).toLong()
  val b1 = byteAt(data, i + 1).toLong()
  val b2 = byteAt(data, i + 2).toLong()
  val b3 = byteAt(data, i + 3).toLong()
  b0 + b1 * 256i64 + b2 * 65536i64 + b3 * 16777216i64
}

func flagSet(flags: in Int, bit: in Int): Bool = (flags / bit) % 2 == 1

/// The bytes a gzip stream (one member) decompresses to.  The trailer's length is checked,
/// so a truncated download that the checksum somehow let through still fails loudly.
pub func gunzip(data: in slice[Byte]): Result[List[Int], String] {
  val n = data.length
  if n < 18 or byteAt(data, 0) != 31 or byteAt(data, 1) != 139 {
    return Err(error = "not a gzip stream")
  }
  if byteAt(data, 2) != 8 {
    return Err(error = "unsupported gzip compression method " + Str.fromInt(byteAt(data, 2)))
  }
  val flags = byteAt(data, 3)
  var pos = 10
  if flagSet(flags, 4) {
    pos = pos + 2 + byteAt(data, pos) + byteAt(data, pos + 1) * 256
  }
  if flagSet(flags, 8) {
    while pos < n and byteAt(data, pos) != 0 {
      pos += 1
    }
    pos += 1
  }
  if flagSet(flags, 16) {
    while pos < n and byteAt(data, pos) != 0 {
      pos += 1
    }
    pos += 1
  }
  if flagSet(flags, 2) {
    pos += 2
  }
  if pos >= n - 8 {
    return Err(error = "the gzip header is truncated")
  }
  val inflated = Deflate.inflate(data, pos, n - 8 - pos)
  val expected = le32(data, n - 4)
  if inflated.count.toLong() % 4294967296i64 != expected {
    return Err(error = "the gzip stream is truncated or corrupt (length " + Str.fromInt(inflated.count) + ")")
  }
  Ok(value = inflated)
}

/// One tar member: its path, type flag (`0` file, `2` symlink, `1` hard link, `5` directory),
/// link target, and where its data sits in the uncompressed archive.
pub record TarEntry {
  name: String
  kind: Int
  linkName: String
  dataOffset: Int
  size: Int
}

val printableAscii: String = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

func cString(buf: in List[Int], off: in Int, maxLen: in Int): String {
  var s = ""
  var i = 0
  while i < maxLen and off + i < buf.count and buf[off + i] != 0 {
    val b = buf[off + i]
    // Archive paths are ASCII in practice; any other byte becomes '?'.
    s = s + (if b >= 32 and b < 127 { Str.substring(printableAscii, b - 32, 1) } else { "?" })
    i += 1
  }
  s
}

// A size or field the archive claims beyond what an Int holds is clamped to this, which no
// real archive reaches: the callers' bounds checks then reject it as truncated.
val tarNumberCap: Int = 2147483647

func parseTarNumber(buf: in List[Int], off: in Int, len: in Int): Int {
  if buf[off] >= 128 {
    var v = buf[off] - 128
    var i = 1
    while i < len {
      if v > 8388607 {
        return tarNumberCap
      }
      v = v * 256 + buf[off + i]
      i += 1
    }
    return v
  }
  var v = 0
  var i = 0
  while i < len {
    val c = buf[off + i]
    if c >= 48 and c <= 55 {
      if v > 268435455 {
        return tarNumberCap
      }
      v = v * 8 + (c - 48)
    }
    i += 1
  }
  v
}

func isZeroBlock(buf: in List[Int], off: in Int): Bool {
  var i = 0
  while i < 512 {
    if buf[off + i] != 0 {
      return false
    }
    i += 1
  }
  true
}

func headerChecksumOk(buf: in List[Int], off: in Int): Bool {
  var sum = 0
  var i = 0
  while i < 512 {
    sum = sum + (if i >= 148 and i < 156 { 32 } else { buf[off + i] })
    i += 1
  }
  sum == parseTarNumber(buf, off + 148, 8)
}

/// The value of `key` in a pax extended header (`<length> <key>=<value>\n` records), or "".
func paxValue(buf: in List[Int], off: in Int, size: in Int, key: in String): String {
  var pos = off
  val limit = off + size
  while pos < limit {
    var len = 0
    var p = pos
    while p < limit and buf[p] >= 48 and buf[p] <= 57 {
      len = len * 10 + (buf[p] - 48)
      p += 1
    }
    if len <= 0 or pos + len > limit {
      return ""
    }
    val record = cString(buf, p + 1, pos + len - (p + 1) - 1)
    val eq = Str.indexOfRaw(record, "=")
    if eq > 0 and Str.substring(record, 0, eq) == key {
      return Str.substring(record, eq + 1)
    }
    pos = pos + len
  }
  ""
}

func roundUp512(n: in Int): Int = ((n + 511) / 512) * 512

/// Reads the member headers of an uncompressed tar archive; a malformed header ends the list.
pub func readTarEntries(buf: in List[Int]): Result[List[TarEntry], String] {
  val entries: List[TarEntry] = newList()
  var pos = 0
  var pendingName = ""
  var pendingLink = ""
  var pendingSize = -1
  while pos + 512 <= buf.count and not isZeroBlock(buf, pos) {
    if not headerChecksumOk(buf, pos) {
      return Err(error = "the tar header at offset " + Str.fromInt(pos) + " has a bad checksum")
    }
    val kind = buf[pos + 156]
    val headerSize = parseTarNumber(buf, pos + 124, 12)
    val dataOff = pos + 512
    if headerSize > buf.count - dataOff {
      return Err(error = "the tar archive is truncated")
    }
    if kind == 120 {
      val path = paxValue(buf, dataOff, headerSize, "path")
      if path.length > 0 {
        pendingName = path
      }
      val link = paxValue(buf, dataOff, headerSize, "linkpath")
      if link.length > 0 {
        pendingLink = link
      }
      val sz = paxValue(buf, dataOff, headerSize, "size")
      if sz.length > 0 {
        match Parse.parseOptInt(sz) {
          case Some(v) -> {
            pendingSize = v
          }
          case None -> ()
        }
      }
    } else if kind == 76 {
      pendingName = cString(buf, dataOff, headerSize)
    } else if kind == 75 {
      pendingLink = cString(buf, dataOff, headerSize)
    } else if kind != 103 {
      var name = pendingName
      if name.length == 0 {
        name = cString(buf, pos, 100)
        val prefix = cString(buf, pos + 345, 155)
        if prefix.length > 0 {
          name = prefix + "/" + name
        }
      }
      val link = if pendingLink.length > 0 { pendingLink } else { cString(buf, pos + 157, 100) }
      val size = if pendingSize >= 0 { pendingSize } else { headerSize }
      val isData = kind == 0 or kind == 48 or kind == 55
      // A pax `size` replaces the header's, so it needs the same bounds check.
      if isData and size > buf.count - dataOff {
        return Err(error = "the tar archive is truncated")
      }
      entries.add(
        TarEntry(
          name = name,
          kind = if kind == 0 { 48 } else { kind },
          linkName = link,
          dataOffset = dataOff,
          size = if isData { size } else { 0 }
        )
      )
      pendingName = ""
      pendingLink = ""
      pendingSize = -1
      pos = pos + 512 + roundUp512(if isData { size } else { headerSize })
      continue
    }
    pos = pos + 512 + roundUp512(headerSize)
  }
  Ok(value = entries)
}

/// `a/./b//c/../d` as `a/b/d`: the path with `.`, empty and `..` segments resolved.
func normalizeTarPath(path: in String): String {
  val segs: List[String] = newList()
  for seg in Str.split(path, "/") {
    if seg == "" or seg == "." {
      // skipped
    } else if seg == ".." {
      if segs.count > 0 {
        segs.removeAt(segs.count - 1)
      }
    } else {
      segs.add(seg)
    }
  }
  Str.joinList("/", segs)
}

func tarDirname(path: in String): String {
  val slash = Str.lastIndexOfRaw(path, "/")
  if slash < 0 {
    ""
  } else {
    Str.substring(path, 0, slash)
  }
}

func findTarEntry(entries: in List[TarEntry], name: in String): Option[TarEntry] {
  val want = normalizeTarPath(name)
  for e in entries {
    if e.kind != 53 and normalizeTarPath(e.name) == want {
      return Some(value = e)
    }
  }
  None
}

/// The bytes of the member `name`, following symbolic and hard links (a `libfoo.dylib` that
/// points at `libfoo.3.dylib` yields the real file's bytes).
pub func extractTarMember(buf: in List[Int], entries: in List[TarEntry], name: in String): Result[List[Int], String] {
  var current = name
  var hops = 0
  while hops < 16 {
    match findTarEntry(entries, current) {
      case None -> return Err(error = "the archive has no member '" + name + "'")
      case Some(e) -> {
        if e.kind == 50 {
          current = if Str.startsWith(e.linkName, "/") {
            e.linkName
          } else {
            tarDirname(normalizeTarPath(e.name)) + "/" + e.linkName
          }
        } else if e.kind == 49 {
          // A hard link names its target by the target's path in the archive, from the root.
          current = e.linkName
        } else {
          val bytes: List[Int] = newList()
          var i = 0
          while i < e.size {
            bytes.add(buf[e.dataOffset + i])
            i += 1
          }
          return Ok(value = bytes)
        }
      }
    }
    hops += 1
  }
  Err(error = "'" + name + "' is a chain of links that never reaches a file")
}
