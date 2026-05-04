// std/string.l - String manipulation and inspection.
//
// Safe, contract-driven string operations. All functions that may fail
// return Result or Option; none throw exceptions.
@runtime_checked
package Std.String

// ---------------------------------------------------------------------------
// String inspection and basic operations.
// ---------------------------------------------------------------------------

// Return the number of characters in a string.
@pure
@stable(since="1.0")
pub func length(s: in String): Int {
  s.length
}

// Check if a string is empty.
@pure
@stable(since="1.0")
pub func isEmpty(s: in String): Bool {
  s.length == 0
}

// Check if a string is not empty.
@pure
@stable(since="1.0")
pub func isNotEmpty(s: in String): Bool {
  s.length > 0
}

// Return a string with leading and trailing whitespace removed.
@pure
@stable(since="1.0")
pub func trim(s: in String): String {
  s.trim()
}

// Return a string with leading whitespace removed.
@pure
@stable(since="1.0")
pub func trimStart(s: in String): String {
  s.trimStart()
}

// Return a string with trailing whitespace removed.
@pure
@stable(since="1.0")
pub func trimEnd(s: in String): String {
  s.trimEnd()
}

// ---------------------------------------------------------------------------
// Substring and search.
// ---------------------------------------------------------------------------

// Check if a string starts with a prefix.
@pure
@stable(since="1.0")
pub func startsWith(s: in String, prefix: in String): Bool {
  s.startsWith(prefix)
}

// Check if a string ends with a suffix.
@pure
@stable(since="1.0")
pub func endsWith(s: in String, suffix: in String): Bool {
  s.endsWith(suffix)
}

// Check if a string contains a substring.
@pure
@stable(since="1.0")
pub func contains(s: in String, substring: in String): Bool {
  s.contains(substring)
}

// Find the index of a substring, or None if not found.
@pure
@stable(since="1.0")
pub func indexOf(s: in String, substring: in String): Option[Int] {
  val i = s.indexOf(substring)
  if i < 0 { return None }
  return Some(value = i)
}

// Find the final index of a substring, or None if not found.
@pure
@stable(since="1.0")
pub func lastIndexOf(s: in String, substring: in String): Option[Int] {
  val i = s.lastIndexOf(substring)
  if i < 0 { return None }
  return Some(value = i)
}

// Return the suffix beginning at start.
@pure
@stable(since="1.0")
pub func substring(s: in String, start: in Int): String
  requires: start >= 0
  requires: start <= s.length
{
  return s.substring(start)
}

// Return the substring bounded by start and character count.
@pure
@stable(since="1.0")
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
@stable(since="1.0")
pub func toUpper(s: in String): String {
  s.toUpper()
}

// Return a string with all characters converted to lowercase.
@pure
@stable(since="1.0")
pub func toLower(s: in String): String {
  s.toLower()
}

// ---------------------------------------------------------------------------
// String construction and formatting.
// ---------------------------------------------------------------------------

// Repeat a string n times.
@pure
@stable(since="1.0")
pub func repeat(s: in String, count: in Int): String {
  var result = ""
  var i = 0
  while i < count {
    result = result + s
    i += 1
  }
  return result
}

// Replace all occurrences of a substring with another.
@pure
@stable(since="1.0")
pub func replace(s: in String, oldValue: in String, newValue: in String): String {
  s.replace(oldValue, newValue)
}

// Split a string on a separator, returning a slice of the parts.
// Maps to String.Split(string?) — available in .NET 5+.
@pure
@stable(since="1.0")
pub func split(s: in String, separator: in String): slice[String] {
  s.split(separator)
}

// Join a slice of strings with a separator.
// Pure-Lyric implementation using slice indexing; avoids BCL static-method dispatch.
@pure
@stable(since="1.0")
pub func join(separator: in String, parts: in slice[String]): String {
  var result = ""
  var i = 0
  while i < parts.length {
    if i > 0 { result = result + separator }
    result = result + parts[i]
    i += 1
  }
  return result
}

// ---------------------------------------------------------------------------
// String comparison.
// ---------------------------------------------------------------------------

// Compare two strings lexicographically. Returns:
//   < 0 if s1 < s2
//   = 0 if s1 == s2
//   > 0 if s1 > s2
@pure
@stable(since="1.0")
pub func compare(s1: in String, s2: in String): Int {
  if s1 < s2 { return -1 }
  if s1 > s2 { return 1 }
  return 0
}

// Check equality (same as == but as a function for generic contexts).
@pure
@stable(since="1.0")
pub func equals(s1: in String, s2: in String): Bool {
  s1 == s2
}

// Case-insensitive equality.
@pure
@stable(since="1.0")
pub func equalsCaseInsensitive(s1: in String, s2: in String): Bool {
  s1.toLower() == s2.toLower()
}

// ---------------------------------------------------------------------------
// Character access.
// ---------------------------------------------------------------------------

// Get the character at a given index, or None if out of bounds.
@pure
@stable(since="1.0")
pub func charAt(s: in String, index: in Int): Option[Char] {
  if index >= 0 and index < s.length {
    Some(value = s[index])
  } else {
    None
  }
}

// Get the first character, or None if the string is empty.
@pure
@stable(since="1.0")
pub func first(s: in String): Option[Char] {
  if s.length > 0 {
    Some(value = s[0])
  } else {
    None
  }
}

// Get the last character, or None if the string is empty.
@pure
@stable(since="1.0")
pub func last(s: in String): Option[Char] {
  if s.length > 0 {
    Some(value = s[s.length - 1])
  } else {
    None
  }
}
