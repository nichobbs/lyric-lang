//! Ui.Routing — URL path helpers for typed routes (docs/65-ui-library-sketch.md
//! §6.1, D151).
//!
//! `@generate(Ui.Routes)` turns a route union into `parseRoute(url)` and
//! `routeUrl(r)`; the generated code splits and joins paths with these
//! functions.  They are pure, so logic and view packages may build links.
@runtime_checked
@pure
package Ui.Routing

import Std.Core
import Std.Collections
import Std.String
import Std.Parse as P
import Std.Encoding as Enc

/// The decoded segments of `url`'s path: the query (`?…`) and fragment
/// (`#…`) are dropped, empty segments are skipped (so `/a//b/` is `a`, `b`),
/// and each segment is percent-decoded.  `None` when a segment holds an
/// invalid escape or decodes to invalid UTF-8.
pub func pathSegments(url: in String): Option[List[String]] {
  var path = url
  match indexOf(path, "#") {
    case Some(i) -> {
      path = substring(path, 0, i)
    }
    case None -> ()
  }
  match indexOf(path, "?") {
    case Some(i) -> {
      path = substring(path, 0, i)
    }
    case None -> ()
  }
  val segs: List[String] = newList()
  for raw in split(path, "/") {
    if raw.length > 0 {
      match decodeSegment(raw) {
        case Some(s) -> segs.add(s)
        case None -> return None
      }
    }
  }
  return Some(value = segs)
}

/// `/` followed by `segs`, each percent-encoded, joined by `/`.
pub func joinPath(segs: in List[String]): String {
  var acc = ""
  for s in segs {
    acc = acc + "/" + encodeSegment(s)
  }
  return if acc.length == 0 then "/" else acc
}

/// `s` with every byte outside the RFC 3986 unreserved set
/// (`A-Z a-z 0-9 - . _ ~`) percent-encoded as UTF-8.
pub func encodeSegment(s: in String): String {
  val bytes = Enc.encodeUtf8(s)
  var acc = ""
  var i = 0
  while i < bytes.length {
    val b = bytes[i].toInt()
    if isUnreserved(b) {
      acc = acc + Enc.codepointToString(b)
    } else {
      acc = acc + "%" + hexDigit(b / 16) + hexDigit(b % 16)
    }
    i += 1
  }
  return acc
}

/// `s` with each `%XX` escape decoded and the result read as UTF-8; `None`
/// for a malformed escape or invalid UTF-8.
pub func decodeSegment(s: in String): Option[String] {
  if not contains(s, "%") {
    return Some(value = s)
  }
  val bytes = Enc.encodeUtf8(s)
  val decoded: List[Byte] = newList()
  var i = 0
  while i < bytes.length {
    val b = bytes[i]
    if b == 37u8 {
      if i + 2 >= bytes.length {
        return None
      }
      val hi = hexValue(bytes[i + 1].toInt())
      val lo = hexValue(bytes[i + 2].toInt())
      if hi < 0 or lo < 0 {
        return None
      }
      decoded.add((hi * 16 + lo).toByte())
      i += 3
    } else {
      decoded.add(b)
      i += 1
    }
  }
  return Enc.tryDecodeUtf8(decoded.toArray())
}

/// `s` as a whole `Int`, or `None`.
pub func intSegment(s: in String): Option[Int] {
  return match P.parseOptLong(s) {
    case Some(n) -> if n >= -2147483648 and n <= 2147483647 then Some(value = n.toInt()) else None
    case None -> None
  }
}

/// `s` as a whole `Long`, or `None`.
pub func longSegment(s: in String): Option[Long] {
  return P.parseOptLong(s)
}

func isUnreserved(b: in Int): Bool {
  return (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b == 45 or b == 46 or b == 95 or
    b == 126
}

func hexDigit(n: in Int): String {
  return substring("0123456789ABCDEF", n, 1)
}

func hexValue(c: in Int): Int {
  if c >= 48 and c <= 57 {
    return c - 48
  }
  if c >= 65 and c <= 70 {
    return c - 55
  }
  if c >= 97 and c <= 102 {
    return c - 87
  }
  return -1
}
