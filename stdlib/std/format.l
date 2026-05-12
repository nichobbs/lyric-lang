// std/format.l - Number and string formatting utilities.
//
// Complements `Std.Parse` (string → value) with the reverse direction
// (value → formatted string) for cases where the default `"" + n`
// string interpolation is insufficient.
//
// Three tiers:
//
//   1. Pure-Lyric helpers (`zeroPad`, `hexPad`) that compose the
//      trampolines below without adding new host calls.
//
//   2. Trampolines into BCL instance methods via `Std.FormatHost`
//      for hex formatting and fixed-point doubles (`toHexString`,
//      `formatFixed`).
//
//   3. Padding trampolines into `System.String.PadLeft / PadRight` via
//      the kernel (`padLeft`, `padRight`).

@runtime_checked
package Std.Format

import Std.FormatHost as Host

// =====================================================================
// Integer hex formatting.
// =====================================================================

/// Format `n` as a lowercase hexadecimal string with no prefix.
/// Negative values are formatted using two's-complement bit patterns
/// (matching `Int32.ToString("x")`).
/// Examples: 255 → "ff", 16 → "10", 0 → "0".
@pure
@stable(since="1.0")
pub func toHexString(n: in Int): String {
  Host.hostIntToString(n, "x")
}

/// Format `n` as an uppercase hexadecimal string with no prefix.
/// Examples: 255 → "FF", 16 → "10".
@pure
@stable(since="1.0")
pub func toHexStringUpper(n: in Int): String {
  Host.hostIntToString(n, "X")
}

// =====================================================================
// Double fixed-point formatting.
// =====================================================================

/// Format `x` with exactly `decimals` digits after the decimal point.
/// Uses the invariant (English) locale — decimal separator is always ".".
/// Examples: `formatFixed(3.14159, 2)` → "3.14", `formatFixed(1.0, 4)` → "1.0000".
@pure
@stable(since="1.0")
pub func formatFixed(x: in Double, decimals: in Int): String
  requires: decimals >= 0
{
  Host.hostDoubleToString(x, "F" + ("" + decimals), Host.hostInvariantCulture())
}

// =====================================================================
// String padding.
// =====================================================================

/// Pad `s` on the left with `ch` until its length reaches `width`.
/// Returns `s` unchanged when `s.length >= width`.
/// Example: `padLeft("42", 5, '0')` → "00042".
@pure
@stable(since="1.0")
pub func padLeft(s: in String, width: in Int, ch: in Char): String {
  val len = s.length
  if len >= width { return s }
  var pad = ""
  var i = 0
  val n = width - len
  while i < n {
    pad = pad + ("" + ch)
    i += 1
  }
  pad + s
}

/// Pad `s` on the right with `ch` until its length reaches `width`.
/// Returns `s` unchanged when `s.length >= width`.
/// Example: `padRight("hi", 5, '.')` → "hi...".
@pure
@stable(since="1.0")
pub func padRight(s: in String, width: in Int, ch: in Char): String {
  val len = s.length
  if len >= width { return s }
  var pad = ""
  var i = 0
  val n = width - len
  while i < n {
    pad = pad + ("" + ch)
    i += 1
  }
  s + pad
}

// =====================================================================
// Composite helpers — pure Lyric, no new host calls.
// =====================================================================

/// Left-pad the decimal representation of `n` with zeros to at least
/// `width` characters.  Example: `zeroPad(7, 3)` → "007".
@pure
@stable(since="1.0")
pub func zeroPad(n: in Int, width: in Int): String {
  padLeft("" + n, width, '0')
}

/// Left-pad the lowercase hex representation of `n` with zeros to at
/// least `width` hex characters.  Example: `hexPad(255, 4)` → "00ff".
@pure
@stable(since="1.0")
pub func hexPad(n: in Int, width: in Int): String {
  padLeft(toHexString(n), width, '0')
}

/// Left-pad the uppercase hex representation of `n` with zeros to at
/// least `width` hex characters.  Example: `hexPadUpper(255, 4)` → "00FF".
@pure
@stable(since="1.0")
pub func hexPadUpper(n: in Int, width: in Int): String {
  padLeft(toHexStringUpper(n), width, '0')
}
