//! std/string.l - String manipulation and inspection.
//!
//! Safe, contract-driven string operations. All functions that may fail
//! return Result or Option; none throw exceptions.
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
{
  return s.substring(start, s.length - start)
}

// Return the substring bounded by start and character count.
@pure
@stable(since = "1.0")
pub func substring(s: in String, start: in Int, count: in Int): String
  requires: start >= 0
  requires: count >= 0
  requires: start + count <= s.length
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
pub func repeat(s: in String, count: in Int): String {
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
pub func split(s: in String, separator: in String): slice[String] {
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
  if s1 < s2 {
    return -1
  }
  if s1 > s2 {
    return 1
  }
  return 0
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
// Get the character at a given index, or None if out of bounds.
@pure
@stable(since = "1.0")
pub func charAt(s: in String, index: in Int): Option[Char] {
  if index >= 0 and index < s.length {
    Some(value = s[index])
  } else {
    None
  }
}

// Get the first character, or None if the string is empty.
@pure
@stable(since = "1.0")
pub func first(s: in String): Option[Char] {
  if s.length > 0 {
    Some(value = s[0])
  } else {
    None
  }
}

// Get the last character, or None if the string is empty.
@pure
@stable(since = "1.0")
pub func last(s: in String): Option[Char] {
  if s.length > 0 {
    Some(value = s[s.length - 1])
  } else {
    None
  }
}
