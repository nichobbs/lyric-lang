//! std/string.l - String manipulation and inspection.
//!
//! Safe, contract-driven string operations. Functions that may fail on
//! untrusted input return `Result` or `Option`; functions that document a
//! precondition (`requires:`) panic via `PreconditionViolated` when the
//! caller violates it (see `substring`, `repeat`).
@runtime_checked
package Std.String

import Std.Core
import Std.Collections
import Std.StringHost as SH

// ---------------------------------------------------------------------------
// String inspection and basic operations.
// ---------------------------------------------------------------------------
// Return the number of characters in a string.
@pure
@stable(since = "1.0")
pub func length(s: in String): Int {
  s.length
}

// Check if a string is empty.
@pure
@stable(since = "1.0")
pub func isEmpty(s: in String): Bool {
  s.length == 0
}

// Check if a string is not empty.
@pure
@stable(since = "1.0")
pub func isNotEmpty(s: in String): Bool {
  s.length > 0
}

// Return a string with leading and trailing whitespace removed.
@pure
@stable(since = "1.0")
pub func trim(s: in String): String {
  s.trim()
}

// Return a string with leading whitespace removed.
@pure
@stable(since = "1.0")
pub func trimStart(s: in String): String {
  s.trimStart()
}

// Return a string with trailing whitespace removed.
@pure
@stable(since = "1.0")
pub func trimEnd(s: in String): String {
  s.trimEnd()
}

// Check if a string is in Unicode Normalization Form C (NFC).
@pure
@stable(since = "1.0")
pub func isNormalized(s: in String): Bool {
  s.isNormalized()
}

// Return a string converted to Unicode Normalization Form C (NFC).
@pure
@stable(since = "1.0")
pub func normalize(s: in String): String {
  s.normalize()
}

// ---------------------------------------------------------------------------
// Substring and search.
// ---------------------------------------------------------------------------
// Check if a string starts with a prefix.
@pure
@stable(since = "1.0")
pub func startsWith(s: in String, prefix: in String): Bool {
  s.startsWith(prefix)
}

// Check if a string ends with a suffix.
@pure
@stable(since = "1.0")
pub func endsWith(s: in String, suffix: in String): Bool {
  s.endsWith(suffix)
}

// Check if a string contains a substring.
@pure
@stable(since = "1.0")
pub func contains(s: in String, substring: in String): Bool {
  s.contains(substring)
}

// Find the index of a substring, or None if not found.
@pure
@stable(since = "1.0")
pub func indexOf(s: in String, substring: in String): Option[Int] {
  val i = s.indexOf(substring)
  if i < 0 {
    return None
  }
  return Some(value = i)
}

// Find the final index of a substring, or None if not found.
@pure
@stable(since = "1.0")
pub func lastIndexOf(s: in String, substring: in String): Option[Int] {
  val i = s.lastIndexOf(substring)
  if i < 0 {
    return None
  }
  return Some(value = i)
}

// Find the index of a substring, or -1 if not found (raw host semantics).
// The explicit spelling for callers that want the sentinel-int form —
// with `import Std.String` in scope the method spelling `.indexOf` is the
// UFCS form of the Option-returning `indexOf` above on both targets
// (#6496), so index arithmetic written against -1 should call this.
@pure
@stable(since = "1.0")
pub func indexOfRaw(s: in String, substring: in String): Int {
  s.indexOf(substring)
}

// Find the final index of a substring, or -1 if not found (raw host
// semantics).  See `indexOfRaw`.
@pure
@stable(since = "1.0")
pub func lastIndexOfRaw(s: in String, substring: in String): Int {
  s.lastIndexOf(substring)
}

// Find the index of a substring at or after `from`, or None if not found.
// Ordinal comparison on every target. An empty substring matches at
// `from`. Scanning forward with this instead of re-slicing the remainder
// keeps repeated searches linear in the input (#7258).
@pure
@stable(since = "1.0")
pub func indexOfFrom(s: in String, substring: in String, from: in Int): Option[Int]
  requires: from >= 0
  requires: from <= s.length
{
  val i = SH.hostIndexOfFrom(s, substring, from)
  if i < 0 {
    return None
  }
  return Some(value = i)
}

// Find the index of a substring at or after `from`, or -1 if not found.
// The sentinel-int form of `indexOfFrom`, for index arithmetic.
@pure
@stable(since = "1.0")
pub func indexOfFromRaw(s: in String, substring: in String, from: in Int): Int
  requires: from >= 0
  requires: from <= s.length
{
  SH.hostIndexOfFrom(s, substring, from)
}

// Return the suffix beginning at start.
@pure
@stable(since = "1.0")
pub func substring(s: in String, start: in Int): String
  requires: start >= 0
  requires: start <= s.length
  ensures: result.length == s.length - start
{
  return s.substring(start, s.length - start)
}

// Return the substring bounded by start and character count.
@pure
@stable(since = "1.0")
pub func substring(s: in String, start: in Int, count: in Int): String
  requires: start >= 0
  requires: count >= 0
  requires: count <= s.length - start
  ensures: result.length == count
{
  return s.substring(start, count)
}

// ---------------------------------------------------------------------------
// Case conversion.
// ---------------------------------------------------------------------------
// Return a string with all characters converted to uppercase.
@pure
@stable(since = "1.0")
pub func toUpper(s: in String): String {
  s.toUpper()
}

// Return a string with all characters converted to lowercase.
@pure
@stable(since = "1.0")
pub func toLower(s: in String): String {
  s.toLower()
}

// ---------------------------------------------------------------------------
// String construction and formatting.
// ---------------------------------------------------------------------------
// Repeat a string n times.
@pure
@stable(since = "1.0")
pub func repeat(s: in String, count: in Int): String
  requires: count >= 0
  requires: s.length == 0 or count <= 2147483647 / s.length
  ensures: result.length == s.length * count
{
  val sb = StringBuilder.new()
  var i = 0
  while i < count {
    sb.append(s)
    i += 1
  }
  sb.toString()
}

// Replace all occurrences of a substring with another.
@pure
@stable(since = "1.0")
pub func replace(s: in String, oldValue: in String, newValue: in String): String {
  s.replace(oldValue, newValue)
}

// Split a string on a separator, returning a slice of the parts.
// Matches .NET semantics: an empty separator yields the whole string
// unchanged; adjacent separators produce empty parts; matching is ordinal,
// left to right and non-overlapping.
//
// Single forward scan with the host's ordinal from-index search: each part is
// copied exactly once and no candidate position allocates. Re-slicing the
// remainder after every match made this quadratic in the input length, which
// dominated compile time for callers that split whole source files by line.
@pure
@stable(since = "1.0")
pub func split(s: in String, separator: in String): slice[String]
  ensures: result.length >= 1
{
  val parts: List[String] = newList()
  val sepLen = separator.length
  if sepLen == 0 {
    parts.add(s)
    return parts.toArray()
  }
  var partStart = 0
  var more = true
  while more {
    val i = SH.hostIndexOfFrom(s, separator, partStart)
    if i < 0 {
      more = false
    } else {
      parts.add(s.substring(partStart, i - partStart))
      partStart = i + sepLen
    }
  }
  parts.add(s.substring(partStart, s.length - partStart))
  parts.toArray()
}

// Join a slice of strings with a separator. Linear in the total length.
@pure
@stable(since = "1.0")
pub func join(separator: in String, parts: in slice[String]): String {
  val sb = StringBuilder.new()
  var i = 0
  while i < parts.length {
    if i > 0 {
      sb.append(separator)
    }
    sb.append(parts[i])
    i += 1
  }
  sb.toString()
}

// Join a list of strings with a separator. Linear in the total length.
@pure
@stable(since = "1.0")
pub func joinList(sep: in String, xs: in List[String]): String {
  val sb = StringBuilder.new()
  var i = 0
  while i < xs.count {
    if i > 0 {
      sb.append(sep)
    }
    sb.append(xs[i])
    i += 1
  }
  sb.toString()
}

// ---------------------------------------------------------------------------
// StringBuilder.
// ---------------------------------------------------------------------------
/// A mutable string accumulator with amortised O(1) append.
///
/// `a + b` copies both operands, so building a string with `acc = acc + x`
/// in a loop is quadratic in the result length. Append the pieces to a
/// `StringBuilder` and call `toString()` once instead:
///
/// ```lyric
/// val sb = StringBuilder.new()
/// for part in parts {
///   sb.append(part)
///   sb.appendChar(',')
/// }
/// val csv = sb.toString()
/// ```
///
/// Backed by `System.Text.StringBuilder` on .NET, `java.lang.StringBuilder`
/// on the JVM, and a part list materialised with a single allocation on
/// native.
@stable(since = "1.0")
pub opaque type StringBuilder {
  host: SH.HostStringBuilder
}

/// Create an empty builder.
@stable(since = "1.0")
pub func StringBuilder.new(): StringBuilder {
  StringBuilder(host = SH.hostNewBuilder())
}

/// Append a string.
@stable(since = "1.0")
pub func StringBuilder.append(sb: in StringBuilder, s: in String): Unit {
  SH.hostAppend(sb.host, s)
}

/// Append a single character.
@stable(since = "1.0")
pub func StringBuilder.appendChar(sb: in StringBuilder, c: in Char): Unit {
  SH.hostAppendChar(sb.host, c)
}

/// Return the accumulated string. The builder stays usable; later appends
/// do not affect strings already returned.
@stable(since = "1.0")
pub func StringBuilder.toString(sb: in StringBuilder): String {
  SH.hostBuilderToString(sb.host)
}

// ---------------------------------------------------------------------------
// String comparison.
// ---------------------------------------------------------------------------
// Compare two strings lexicographically. Returns:
//   < 0 if s1 < s2
//   = 0 if s1 == s2
//   > 0 if s1 > s2
@pure
@stable(since = "1.0")
pub func compare(s1: in String, s2: in String): Int {
  val c = SH.hostCompareOrdinal(s1, s2)
  if c < 0 {
    -1
  } else if c > 0 {
    1
  } else {
    0
  }
}

// Check equality (same as == but as a function for generic contexts).
@pure
@stable(since = "1.0")
pub func equals(s1: in String, s2: in String): Bool {
  s1 == s2
}

// Case-insensitive equality.
@pure
@stable(since = "1.0")
pub func equalsCaseInsensitive(s1: in String, s2: in String): Bool {
  // ASCII input, the common case (HTTP header names, identifiers), is
  // compared in place; only text with a non-ASCII character pays for the
  // two lowercase copies (#7269).
  match SH.hostAsciiCaseCompare(s1, s2) {
    case 1 -> true
    case 0 -> false
    case _ -> s1.toLower() == s2.toLower()
  }
}

// ---------------------------------------------------------------------------
// Conversion from primitives.
// ---------------------------------------------------------------------------
// Convert an integer to its decimal string representation.
@pure
@stable(since = "1.0")
pub func fromInt(n: in Int): String {
  toString(n)
}

// ---------------------------------------------------------------------------
// Character access.
// ---------------------------------------------------------------------------
// A `Char` is a BMP scalar value, never a UTF-16 surrogate half (docs/01
// §2.1). `s[i]` therefore fails on an index holding a surrogate; these
// accessors are the non-failing `Char` views (`None` there) plus the two
// views that can see every position: raw code units and Unicode scalar
// values (code points). Indices and `s.length` count code units: UTF-16
// units on .NET and the JVM, UTF-8 bytes on native (D-N-006).
//
// The `Option[Char]` postconditions below go through the non-generic
// `noChar`: the stage-0 seed compiler that builds the stdlib cannot infer
// `isNone`'s type argument from `result` inside a contract clause (#7466,
// fixed in the compiler itself; the seed predates the fix), and
// `--target native` does not yet lower the explicit `isNone[Char](result)`
// spelling.
@pure
func noChar(o: in Option[Char]): Bool {
  match o {
    case Some(_) -> false
    case None -> true
  }
}

/// The code unit at `index` as an `Int`: a UTF-16 unit (0..65535, surrogate
/// halves included) on .NET and the JVM, a UTF-8 byte (0..255) on native.
/// The free-function form of `s.codeUnitAt(index)`.
@pure
@stable(since = "1.0")
pub func codeUnitAt(s: in String, index: in Int): Int
  requires: index >= 0 and index < s.length
{
  SH.hostCodeUnitAt(s, index)
}

/// The Unicode scalar value (code point) whose encoding starts at code-unit
/// index `index`. A UTF-16 surrogate pair decodes to its supplementary-plane
/// scalar (`codePointAt("\u{1F600}", 0)` is `0x1F600`); on native a UTF-8
/// sequence decodes the same way. An index that does not start a well-formed
/// encoding — a lone or trailing surrogate, or a malformed UTF-8 byte —
/// yields U+FFFD REPLACEMENT CHARACTER, so the result is always a scalar
/// value that `Std.Encoding.codepointToString` accepts.
@pure
@stable(since = "1.0")
pub func codePointAt(s: in String, index: in Int): Int
  requires: index >= 0 and index < s.length
  ensures: result >= 0 and result <= 1114111 and (result < 55296 or result > 57343)
{
  val (cp, _) = decodeCodePointAt(s, index)
  cp
}

/// Every Unicode scalar value of `s`, in order, decoded as `codePointAt`
/// does: each ill-formed code unit becomes one U+FFFD. This is how to walk a
/// string's characters — a `String` is not itself iterable:
///
/// ```lyric
/// for cp in codePoints(s) {
///   ...
/// }
/// ```
@pure
@stable(since = "1.0")
pub func codePoints(s: in String): slice[Int] {
  val points: List[Int] = newList()
  var i = 0
  while i < s.length {
    val (cp, width) = decodeCodePointAt(s, i)
    points.add(cp)
    i = i + width
  }
  points.toArray()
}

// The scalar value starting at `index` and the number of code units it
// occupies; (U+FFFD, 1) when `index` does not start a well-formed encoding.
@pure
func decodeCodePointAt(s: in String, index: in Int): (Int, Int) {
  if SH.hostCodeUnitsAreUtf8() {
    decodeUtf8At(s, index)
  } else {
    decodeUtf16At(s, index)
  }
}

@pure
func decodeUtf16At(s: in String, index: in Int): (Int, Int) {
  val u = SH.hostCodeUnitAt(s, index)
  if u < 55296 or u > 57343 {
    return (u, 1)
  }
  if u <= 56319 and index + 1 < s.length {
    val lo = SH.hostCodeUnitAt(s, index + 1)
    if lo >= 56320 and lo <= 57343 {
      return (65536 + (u - 55296) * 1024 + (lo - 56320), 2)
    }
  };
  (65533, 1)
}

// Strict UTF-8 (Unicode §3.9, Table 3-7): no overlong forms, no encoded
// surrogates, nothing above U+10FFFF.
@pure
func decodeUtf8At(s: in String, index: in Int): (Int, Int) {
  val b0 = SH.hostCodeUnitAt(s, index)
  if b0 < 128 {
    return (b0, 1)
  }
  val n = s.length
  if b0 >= 194 and b0 <= 223 {
    if index + 1 < n {
      val b1 = SH.hostCodeUnitAt(s, index + 1)
      if isContinuationByte(b1) {
        return ((b0 - 192) * 64 + (b1 - 128), 2)
      }
    }
    return (65533, 1)
  }
  if b0 >= 224 and b0 <= 239 {
    if index + 2 < n {
      val b1 = SH.hostCodeUnitAt(s, index + 1)
      val b2 = SH.hostCodeUnitAt(s, index + 2)
      val lo1 = if b0 == 224 { 160 } else { 128 }
      val hi1 = if b0 == 237 { 159 } else { 191 }
      if b1 >= lo1 and b1 <= hi1 and isContinuationByte(b2) {
        return ((b0 - 224) * 4096 + (b1 - 128) * 64 + (b2 - 128), 3)
      }
    }
    return (65533, 1)
  }
  if b0 >= 240 and b0 <= 244 {
    if index + 3 < n {
      val b1 = SH.hostCodeUnitAt(s, index + 1)
      val b2 = SH.hostCodeUnitAt(s, index + 2)
      val b3 = SH.hostCodeUnitAt(s, index + 3)
      val lo1 = if b0 == 240 { 144 } else { 128 }
      val hi1 = if b0 == 244 { 143 } else { 191 }
      if b1 >= lo1 and b1 <= hi1 and isContinuationByte(b2) and isContinuationByte(b3) {
        return ((b0 - 240) * 262144 + (b1 - 128) * 4096 + (b2 - 128) * 64 + (b3 - 128), 4)
      }
    }
    return (65533, 1)
  };
  (65533, 1)
}

@pure
func isContinuationByte(b: in Int): Bool {
  b >= 128 and b <= 191
}

// The code unit at `index` is a `Char` on its own: a UTF-16 unit outside the
// surrogate range, or (native) a byte that starts the well-formed encoding of
// a BMP scalar value.  A UTF-8 decode of width 1 that yields U+FFFD is the
// decoder's stand-in for an ill-formed byte (a real U+FFFD takes 3 bytes).
@pure
func isCharBoundaryUnit(s: in String, index: in Int): Bool {
  if SH.hostCodeUnitsAreUtf8() {
    val (cp, width) = decodeUtf8At(s, index)
    cp <= 65535 and not (cp == 65533 and width == 1)
  } else {
    val u = SH.hostCodeUnitAt(s, index)
    u < 55296 or u > 57343
  }
}

// The character at `index`, or `None` when `index` is out of bounds or the
// code unit there is not a `Char` on its own (a surrogate half on
// .NET/JVM; not the start of a BMP character's encoding on native) — the
// non-failing counterpart of `s[index]`.
@pure
@stable(since = "1.0")
pub func charAt(s: in String, index: in Int): Option[Char]
  ensures: (index >= 0 and index < s.length) or noChar(result)
{
  // Bound with its type: `--target native` cannot infer `None`'s type
  // argument from the declared return type once the `ensures` clause has
  // been lowered.
  val found: Option[Char] = if index >= 0 and index < s.length and isCharBoundaryUnit(s, index) {
    Some(value = s[index])
  } else {
    None
  }
  found
}

/// The character at `index`, or U+FFFD REPLACEMENT CHARACTER wherever
/// `charAt` would give `None` (a surrogate half on .NET/JVM; a byte that
/// does not start a BMP character on native). For scanners that dispatch on
/// ASCII or BMP syntax — delimiters, digits, whitespace — over text that may
/// contain supplementary-plane characters: no delimiter is U+FFFD, so the
/// scan steps over such characters one code unit at a time, and copying the
/// text between delimiters with `substring` keeps them intact.
@pure
@stable(since = "1.0")
pub func charAtOrReplacement(s: in String, index: in Int): Char
  requires: index >= 0 and index < s.length
{
  if isCharBoundaryUnit(s, index) {
    s[index]
  } else {
    '\u{fffd}'
  }
}

// The first character, or `None` if the string is empty or starts with a
// code unit that is not a `Char` (see `charAt`).
@pure
@stable(since = "1.0")
pub func first(s: in String): Option[Char]
  ensures: s.length > 0 or noChar(result)
{
  charAt(s, 0)
}

// The last code unit as a character, or `None` if the string is empty or
// that unit is not a `Char` (the trailing half of a surrogate pair on
// .NET/JVM, the last byte of a multi-byte sequence on native).
@pure
@stable(since = "1.0")
pub func last(s: in String): Option[Char]
  ensures: s.length > 0 or noChar(result)
{
  charAt(s, s.length - 1)
}
