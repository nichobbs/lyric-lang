//! Storage.Port, native — the operations of `storage_port_managed.l` for
//! `--target native`, over the standard library.
//!
//! Nothing here throws: `Std.File`, `Std.Directory` and `Std.Encoding` report
//! failures as data on this target, and the two operations the standard
//! library does not offer are written out below:
//!
//!   - **MD5**, for the ETag (the single-part S3 scheme the other targets
//!     compute with their platform digest). RFC 1321, with the 32-bit
//!     arithmetic done in `Long` and masked, as `Std.Hash`'s native SHA
//!     kernels do. An integrity tag, not a signature.
//!   - **The full path**: `path` made absolute against the working directory,
//!     with `.` and `..` segments resolved by name. Like
//!     `System.IO.Path.GetFullPath` it does not touch the filesystem and does
//!     not resolve symbolic links.
//!
//! Internal: only `Storage` should import this.
@cfg(target = "native")
@io
package Storage.Port

import Std.Core
import Std.Collections
import Std.Directory as Directory
import Std.Encoding
import Std.Environment as Environment
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.String as Str

pub func portDecodeBase64(data: in String): Result[slice[Byte], String] {
  match tryDecodeBase64(data) {
    case Some(bytes) -> Ok(bytes)
    case None -> Err("the input is not valid base64")
  }
}

pub func portEncodeBase64(bytes: in slice[Byte]): String {
  encodeBase64(bytes)
}

// ── MD5 (RFC 1321) ───────────────────────────────────────────────────────
// floor(2^32 * abs(sin(i + 1))) for i in 0 ..< 64.
func md5Constants(): slice[Long] {
  [
    0xD76AA478i64,
    0xE8C7B756i64,
    0x242070DBi64,
    0xC1BDCEEEi64,
    0xF57C0FAFi64,
    0x4787C62Ai64,
    0xA8304613i64,
    0xFD469501i64,
    0x698098D8i64,
    0x8B44F7AFi64,
    0xFFFF5BB1i64,
    0x895CD7BEi64,
    0x6B901122i64,
    0xFD987193i64,
    0xA679438Ei64,
    0x49B40821i64,
    0xF61E2562i64,
    0xC040B340i64,
    0x265E5A51i64,
    0xE9B6C7AAi64,
    0xD62F105Di64,
    0x02441453i64,
    0xD8A1E681i64,
    0xE7D3FBC8i64,
    0x21E1CDE6i64,
    0xC33707D6i64,
    0xF4D50D87i64,
    0x455A14EDi64,
    0xA9E3E905i64,
    0xFCEFA3F8i64,
    0x676F02D9i64,
    0x8D2A4C8Ai64,
    0xFFFA3942i64,
    0x8771F681i64,
    0x6D9D6122i64,
    0xFDE5380Ci64,
    0xA4BEEA44i64,
    0x4BDECFA9i64,
    0xF6BB4B60i64,
    0xBEBFBC70i64,
    0x289B7EC6i64,
    0xEAA127FAi64,
    0xD4EF3085i64,
    0x04881D05i64,
    0xD9D4D039i64,
    0xE6DB99E5i64,
    0x1FA27CF8i64,
    0xC4AC5665i64,
    0xF4292244i64,
    0x432AFF97i64,
    0xAB9423A7i64,
    0xFC93A039i64,
    0x655B59C3i64,
    0x8F0CCC92i64,
    0xFFEFF47Di64,
    0x85845DD1i64,
    0x6FA87E4Fi64,
    0xFE2CE6E0i64,
    0xA3014314i64,
    0x4E0811A1i64,
    0xF7537E82i64,
    0xBD3AF235i64,
    0x2AD7D2BBi64,
    0xEB86D391i64
  ]
}

// The per-round left-rotation amounts.
func md5Shifts(): slice[Int] {
  [
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    7,
    12,
    17,
    22,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    5,
    9,
    14,
    20,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    4,
    11,
    16,
    23,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21,
    6,
    10,
    15,
    21
  ]
}

func rotl32(x: in Long, n: in Int): Long {
  x.shl(n).or(x.shr(32 - n)).and(0xFFFFFFFFi64)
}

func byteOf(bytes: in List[Byte], i: in Int): Long {
  bytes[i].toInt().and(255).toLong()
}

// The little-endian 32-bit word at `at`.
func wordLE32(m: in List[Byte], at: in Int): Long {
  byteOf(m, at).or(byteOf(m, at + 1).shl(8)).or(byteOf(m, at + 2).shl(16)).or(byteOf(m, at + 3).shl(24))
}

func appendWordLE32(digest: in List[Byte], v: in Long): Unit {
  digest.add(v.and(255i64).toInt().toByte())
  digest.add(v.shr(8).and(255i64).toInt().toByte())
  digest.add(v.shr(16).and(255i64).toInt().toByte())
  digest.add(v.shr(24).and(255i64).toInt().toByte())
}

// `bytes`, a 0x80 byte, zero fill to 56 mod 64, then the length in bits as a
// little-endian 64-bit integer.
func md5Pad(bytes: in slice[Byte]): List[Byte] {
  val m: List[Byte] = newList()
  var i = 0
  while i < bytes.length {
    m.add(bytes[i])
    i = i + 1
  }
  m.add(128.toByte())
  while m.count % 64 != 56 {
    m.add(0.toByte())
  }
  val bits = bytes.length.toLong() * 8i64
  var p = 0
  while p < 8 {
    m.add(bits.shr(p * 8).and(255i64).toInt().toByte())
    p = p + 1
  }
  m
}

func md5(bytes: in slice[Byte]): slice[Byte] {
  val k = md5Constants()
  val s = md5Shifts()
  val m = md5Pad(bytes)
  val mask = 0xFFFFFFFFi64
  var a0 = 0x67452301i64
  var b0 = 0xEFCDAB89i64
  var c0 = 0x98BADCFEi64
  var d0 = 0x10325476i64
  var base = 0
  while base < m.count {
    var a = a0
    var b = b0
    var c = c0
    var d = d0
    var i = 0
    while i < 64 {
      var f = 0i64
      var g = 0
      if i < 16 {
        f = b.and(c).or(b.xor(mask).and(d))
        g = i
      } else if i < 32 {
        f = d.and(b).or(d.xor(mask).and(c))
        g = (5 * i + 1) % 16
      } else if i < 48 {
        f = b.xor(c).xor(d)
        g = (3 * i + 5) % 16
      } else {
        f = c.xor(b.or(d.xor(mask)))
        g = (7 * i) % 16
      }
      val sum = (a + f + k[i] + wordLE32(m, base + g * 4)).and(mask)
      a = d
      d = c
      c = b
      b = (b + rotl32(sum, s[i])).and(mask)
      i = i + 1
    }
    a0 = (a0 + a).and(mask)
    b0 = (b0 + b).and(mask)
    c0 = (c0 + c).and(mask)
    d0 = (d0 + d).and(mask)
    base = base + 64
  }
  val digest: List[Byte] = newList()
  appendWordLE32(digest, a0)
  appendWordLE32(digest, b0)
  appendWordLE32(digest, c0)
  appendWordLE32(digest, d0)
  digest.toArray()
}

/// The lowercase-hex MD5 of `bytes`.
pub func portEtag(bytes: in slice[Byte]): String {
  Str.toLower(encodeHex(md5(bytes)))
}

// ── Paths ────────────────────────────────────────────────────────────────
func isSeparator(c: in Char, windows: in Bool): Bool {
  c == '/' or (windows and c == '\\')
}

// How many leading characters of an absolute path are its root: `/` on POSIX;
// on Windows a drive (`C:\`), a UNC server and share (`\\server\share\`), or
// a single separator.
func rootLengthOf(path: in String, windows: in Bool): Int {
  if not windows {
    return 1
  }
  if path.length >= 3 and Str.charAtOrReplacement(path, 1) == ':' {
    return 3
  }
  if path.length >= 2 and isSeparator(Str.charAtOrReplacement(path, 0), true) and isSeparator(Str.charAtOrReplacement(path, 1), true) {
    // \\server\share\ : skip two more components.
    var i = 2
    var components = 0
    while i < path.length and components < 2 {
      if isSeparator(Str.charAtOrReplacement(path, i), true) {
        components = components + 1
      }
      i = i + 1
    }
    return i
  }
  1
}

/// The absolute path of `path` with `.` and `..` segments resolved by name;
/// a `..` at the root stays at the root. The filesystem is not consulted.
pub func portFullPath(path: in String): Result[String, String] {
  if path.length == 0 {
    return Err("the path is empty")
  }
  // A NUL would end the path early at the C boundary and name another file.
  if Str.contains(path, "\u{0000}") {
    return Err("the path contains a NUL character")
  }
  val windows = Environment.isWindows()
  val sep = if windows { "\\" } else { "/" }
  val absolute = if Path.isAbsolute(path) { path } else { Path.join(Environment.currentDirectory(), path) }
  val rootLen = rootLengthOf(absolute, windows)
  if rootLen > absolute.length {
    return Err("the path has no root: " + path)
  }
  val segments: List[String] = newList()
  var start = rootLen
  var i = rootLen
  while i <= absolute.length {
    if i == absolute.length or isSeparator(Str.charAtOrReplacement(absolute, i), windows) {
      val segment = Str.substring(absolute, start, i - start)
      if segment == ".." {
        if segments.count > 0 {
          segments.removeAt(segments.count - 1)
        }
      } else if segment.length > 0 and segment != "." {
        segments.add(segment)
      }
      start = i + 1
    }
    i = i + 1
  }
  var root = Str.substring(absolute, 0, rootLen)
  if windows {
    root = Str.replace(root, "/", "\\")
    if not Str.endsWith(root, "\\") {
      root = root + "\\"
    }
  }
  var full = root
  var n = 0
  while n < segments.count {
    if n > 0 {
      full = full + sep
    }
    full = full + segments[n]
    n = n + 1
  }
  Ok(full)
}

// ── Files and directories ────────────────────────────────────────────────
pub func portWriteText(path: in String, contents: in String): Result[Unit, String] {
  match File.writeText(path, contents) {
    case Ok(_) -> Ok(())
    case Err(e) -> Err(IOError.message(e))
  }
}

pub func portReadText(path: in String): Result[String, String] {
  match File.readText(path) {
    case Ok(text) -> Ok(text)
    case Err(e) -> Err(IOError.message(e))
  }
}

pub func portFileExists(path: in String): Bool {
  File.fileExists(path)
}

pub func portDeleteFile(path: in String): Result[Unit, String] {
  match File.deleteFile(path) {
    case Ok(_) -> Ok(())
    case Err(e) -> Err(IOError.message(e))
  }
}

pub func portDirectoryExists(path: in String): Bool {
  Directory.exists(path)
}

/// Create `path` and any missing parents. An existing directory is not an
/// error.
pub func portCreateDirectory(path: in String): Result[Unit, String] {
  if Directory.exists(path) {
    return Ok(())
  }
  match Directory.createRecursive(path) {
    case Ok(_) -> Ok(())
    case Err(e) -> Err(IOError.message(e))
  }
}

// `Std.Directory` does not pin whether an entry is a name or a path, so each
// is rebuilt as `dir` joined with the entry's last component.
func underDirectory(dir: in String, entries: in slice[String]): slice[String] {
  val paths: List[String] = newList()
  var i = 0
  while i < entries.length {
    paths.add(Path.join(dir, Path.basename(entries[i])))
    i = i + 1
  }
  paths.toArray()
}

/// The files directly in `dir`, as paths that start with `dir`.
pub func portFiles(dir: in String): Result[slice[String], String] {
  match Directory.enumerateFiles(dir) {
    case Ok(entries) -> Ok(underDirectory(dir, entries))
    case Err(e) -> Err(IOError.message(e))
  }
}

/// The directories directly in `dir`, as paths that start with `dir`.
pub func portDirectories(dir: in String): Result[slice[String], String] {
  match Directory.enumerateDirectories(dir) {
    case Ok(entries) -> Ok(underDirectory(dir, entries))
    case Err(e) -> Err(IOError.message(e))
  }
}
