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

// The raw (still percent-encoded) `name=value` pairs of `url`'s query, in
// order; the fragment is dropped.
func queryPairs(url: in String): List[String] {
  var rest = url
  match indexOf(rest, "#") {
    case Some(i) -> {
      rest = substring(rest, 0, i)
    }
    case None -> ()
  }
  val pairs: List[String] = newList()
  match indexOf(rest, "?") {
    case Some(i) -> {
      for pair in split(substring(rest, i + 1), "&") {
        if pair.length > 0 {
          pairs.add(pair)
        }
      }
    }
    case None -> ()
  }
  return pairs
}

// A query component decoded as `application/x-www-form-urlencoded` does:
// `+` is a space, then `%XX` escapes are decoded.  A literal `+` travels as
// `%2B`, which `withQuery` always writes.
func decodeQueryComponent(s: in String): Option[String] {
  return decodeSegment(replace(s, "+", " "))
}

// The raw `name=value` pair of `url`'s query whose decoded name is `name`
// (the first, if several), or `None`.
func firstQueryPair(url: in String, name: in String): Option[String] {
  for pair in queryPairs(url) {
    val eq = indexOf(pair, "=")
    val rawName = match eq { case Some(i) -> substring(pair, 0, i); case None -> pair }
    match decodeQueryComponent(rawName) {
      case Some(n) -> {
        if n == name {
          return Some(value = pair)
        }
      }
      case None -> ()
    }
  }
  return None
}

/// True when `url`'s query has a pair named `name` (`?name`, `?name=` and
/// `?name=v` all count).  The fragment is ignored and names are
/// percent-decoded.
pub func queryPresent(url: in String, name: in String): Bool {
  return match firstQueryPair(url, name) { case Some(_) -> true; case None -> false }
}

/// The decoded value of the first query pair of `url` named `name`: `+` is a
/// space and `%XX` escapes are decoded.  A pair without `=` has the empty
/// value.  `None` when no pair has that name, or when its value holds an
/// invalid escape or decodes to invalid UTF-8; `queryPresent` tells the two
/// apart.
pub func queryValue(url: in String, name: in String): Option[String] {
  return match firstQueryPair(url, name) {
    case Some(pair) -> match indexOf(pair, "=") {
      case Some(i) -> decodeQueryComponent(substring(pair, i + 1))
      case None -> Some(value = "")
    }
    case None -> None
  }
}

/// `url` with `name=value` appended to its query (`?` for the first pair, `&`
/// after), both percent-encoded; `url` unchanged when `value` is `None`.
pub func withQuery(url: in String, name: in String, value: in Option[String]): String {
  return match value {
    case Some(v) -> url + (if contains(url, "?") then "&" else "?") + encodeSegment(name) + "=" +
      encodeSegment(v)
    case None -> url
  }
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
