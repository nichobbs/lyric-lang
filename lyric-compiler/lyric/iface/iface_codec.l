//! iface_codec.l - the canonical binary encoding of a package interface
//! (docs/70 §9.6): tagged records, LEB128 integers and one string table.
//!
//! Layout of an interface file:
//!
//!   magic       4 bytes, "LYRI"
//!   version     LEB128, the format version
//!   strings     LEB128 count, then each string as LEB128 byte length + UTF-8
//!   body        the records, referring to strings by table index
//!
//! The encoding is canonical: an integer uses the fewest bytes, the string
//! table lists strings in order of first use, and the encoder visits the
//! model in one fixed order, so one interface has exactly one byte image.  The
//! reader rejects anything else (a longer-than-needed integer, a string
//! table entry that is not UTF-8, bytes after the body), which is what lets
//! the bootstrap's reproducibility check compare interface bytes.
package Lyric.Iface

import Std.Core
import Std.Collections
import Std.Encoding as Enc

/// The first four bytes of an interface file.
pub val ifaceMagic0: Int = 76

pub val ifaceMagic1: Int = 89

pub val ifaceMagic2: Int = 82

pub val ifaceMagic3: Int = 73

/// The format version this compiler writes and reads.  Interfaces replace
/// contract metadata outright (docs/70 §12.3); a reader never accepts an
/// older or newer version.
pub val ifaceFormatVersion: Int = 5

/// Collects the body of an interface and the string table it refers to.
/// `err` is the first thing the model could not be encoded as (a type that
/// names a declaration with no DefPath); `encodeIface` returns it.
pub ref record IfaceWriter {
  buf: List[Byte]
  strings: Map[String, Int]
  table: List[String]
  var err: String
}

pub func newIfaceWriter(): IfaceWriter {
  IfaceWriter(buf = newList(), strings = newMap(), table = newList(), err = "")
}

func putByteTo(buf: in List[Byte], b: in Int) {
  buf.add(b.and(255).toByte())
}

func putUTo(buf: in List[Byte], n: in Int) {
  var v = n
  while v >= 128 {
    putByteTo(buf, v.and(127).or(128))
    v = v.shr(7)
  }
  putByteTo(buf, v)
}

/// One raw byte (0..255).
pub func putByte(w: in IfaceWriter, b: in Int) {
  putByteTo(w.buf, b)
}

/// A non-negative integer as LEB128.
pub func putU(w: in IfaceWriter, n: in Int) {
  putUTo(w.buf, n)
}

/// A 64-bit integer as eight little-endian bytes: fixed width keeps it
/// canonical without a sign convention.
pub func putLong(w: in IfaceWriter, n: in Long) {
  var k = 0
  while k < 8 {
    putByteTo(w.buf, n.shr(8 * k).and(255i64).toInt())
    k = k + 1
  }
}

pub func writeFail(w: in IfaceWriter, msg: in String) {
  if w.err.length == 0 {
    w.err = msg
  }
}

pub func putBool(w: in IfaceWriter, b: in Bool) {
  putByteTo(w.buf, if b then 1 else 0)
}

/// The table index of `s`, interning it on first use.
pub func internString(w: in IfaceWriter, s: in String): Int {
  match mapGet(w.strings, s) {
    case Some(i) -> i
    case None -> {
      val i = w.table.count
      w.table.add(s)
      w.strings.add(s, i)
      i
    }
  }
}

/// A string, as its table index.
pub func putStr(w: in IfaceWriter, s: in String) {
  putUTo(w.buf, internString(w, s))
}

/// The complete interface file: magic, version, string table, then the body.
pub func finishIface(w: in IfaceWriter): slice[Byte] {
  val all: List[Byte] = newList()
  putByteTo(all, ifaceMagic0)
  putByteTo(all, ifaceMagic1)
  putByteTo(all, ifaceMagic2)
  putByteTo(all, ifaceMagic3)
  putUTo(all, ifaceFormatVersion)
  putUTo(all, w.table.count)
  for s in w.table {
    val bytes = Enc.encodeUtf8(s)
    putUTo(all, bytes.length)
    var i = 0
    while i < bytes.length {
      all.add(bytes[i])
      i = i + 1
    }
  }
  for b in w.buf {
    all.add(b)
  }
  all.toArray()
}

/// Reads an interface file.  A read never throws: the first problem sets
/// `failed` and `err`, every later read returns a neutral value, and the
/// caller checks `failed` once at the end.
pub ref record IfaceReader {
  data: slice[Byte]
  var pos: Int
  var failed: Bool
  var err: String
  var depth: Int
  strings: List[String]
}

pub func newIfaceReader(data: in slice[Byte]): IfaceReader {
  IfaceReader(data = data, pos = 0, failed = false, err = "", depth = 0, strings = newList())
}

pub func readFail(r: in IfaceReader, msg: in String) {
  if not r.failed {
    r.failed = true
    r.err = msg + " (at byte " + toString(r.pos) + ")"
  }
}

pub func readByte(r: in IfaceReader): Int {
  if r.failed {
    return 0
  }
  if r.pos >= r.data.length {
    readFail(r, "unexpected end of interface")
    return 0
  }
  val b = r.data[r.pos].toInt().and(255)
  r.pos = r.pos + 1
  b
}

/// A LEB128 integer that fits an `Int`.  A longer encoding than the value
/// needs is not canonical and fails.
pub func readU(r: in IfaceReader): Int {
  var result = 0
  var shift = 0
  var more = true
  while more and not r.failed {
    val b = readByte(r)
    if shift > 28 or (shift == 28 and b.and(127) > 7) {
      readFail(r, "integer out of range")
      return 0
    }
    result = result.or(b.and(127).shl(shift))
    if b < 128 {
      more = false
      if b == 0 and shift > 0 {
        readFail(r, "non-canonical integer")
        return 0
      }
    } else {
      shift = shift + 7
    }
  }
  result
}

pub func readLong(r: in IfaceReader): Long {
  var v = 0i64
  var k = 0
  while k < 8 {
    v = v.or(readByte(r).toLong().shl(8 * k))
    k = k + 1
  }
  v
}

/// Enters one level of a nested structure; a file nested deeper than any
/// real type is rejected rather than risking the stack.
pub func readEnter(r: in IfaceReader): Bool {
  r.depth = r.depth + 1
  if r.depth > 200 {
    readFail(r, "nesting too deep")
    return false
  }
  true
}

pub func readLeave(r: in IfaceReader) {
  r.depth = r.depth - 1
}

pub func readBool(r: in IfaceReader): Bool {
  val b = readByte(r)
  if b > 1 {
    readFail(r, "invalid boolean " + toString(b))
    return false
  }
  b == 1
}

/// A string, from its table index.
pub func readStr(r: in IfaceReader): String {
  val i = readU(r)
  if r.failed {
    return ""
  }
  if i >= r.strings.count {
    readFail(r, "string index " + toString(i) + " outside the table of " + toString(r.strings.count))
    return ""
  }
  r.strings[i]
}

/// A count that must not exceed the bytes that remain, so a corrupt length
/// cannot make a reader loop or allocate without bound.
pub func readCount(r: in IfaceReader): Int {
  val n = readU(r)
  if not r.failed and n > r.data.length - r.pos {
    readFail(r, "count " + toString(n) + " exceeds the remaining bytes")
    return 0
  }
  n
}

/// Reads the magic, version and string table.  After a successful call the
/// reader is positioned at the body.
pub func readIfacePrelude(r: in IfaceReader) {
  if readByte(r) != ifaceMagic0 or readByte(r) != ifaceMagic1 or readByte(r) != ifaceMagic2 or readByte(r) != ifaceMagic3 {
    readFail(r, "not an interface file (bad magic)")
    return
  }
  val v = readU(r)
  if r.failed {
    return
  }
  if v != ifaceFormatVersion {
    readFail(
      r,
      "unsupported interface format version " + toString(v) + " (this compiler reads " + toString(ifaceFormatVersion) +
        ")"
    )
    return
  }
  val n = readCount(r)
  var k = 0
  while k < n and not r.failed {
    val len = readCount(r)
    val bytes: List[Byte] = newList()
    var i = 0
    while i < len and not r.failed {
      bytes.add(r.data[r.pos])
      r.pos = r.pos + 1
      i = i + 1
    }
    if not r.failed {
      match Enc.tryDecodeUtf8(bytes.toArray()) {
        case Some(s) -> r.strings.add(s)
        case None -> readFail(r, "string " + toString(k) + " is not UTF-8")
      }
    }
    k = k + 1
  }
}

/// True when every byte has been consumed.
pub func readAtEnd(r: in IfaceReader): Bool {
  r.pos == r.data.length
}
