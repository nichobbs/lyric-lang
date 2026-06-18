//! std/char.l - Unicode character classification, case conversion, and
//! code-point arithmetic.
//!
//! Two tiers per `docs/14-native-stdlib-plan.md` §3:
//!
//!   1. Pure-Lyric helpers for ASCII ranges: `digitValue`, `hexDigitValue`,
//!      `isAscii`.  These use integer subtraction on code-point values and
//!      carry `@pure` + `requires:`/`ensures:` contracts that the Phase 4
//!      prover can reason about.
//!
//!   2. Trampolines into `Std.CharHost` (in `_kernel/`) for the Unicode-
//!      correct surface (`isLetter`, `isDigit`, `isWhiteSpace`, etc.) where
//!      the BCL's `System.Char` statics are the ground truth.
//!
//! `toInt` / `fromInt` bridge between `Char` and `Int` (UTF-16 code units).
//! They are the building blocks for `digitValue`, `hexDigitValue`, and any
//! pure-Lyric text processing that needs arithmetic on characters.
@runtime_checked
package Std.Char

import Std.Core
import Std.CharHost as Host

// =====================================================================
// Classification — Unicode-correct (BCL-backed).
// =====================================================================
/// True for any Unicode letter (Unicode categories Ll, Lm, Lo, Lt, Lu).
@pure
@stable(since = "1.0")
pub func isLetter(c: in Char): Bool {
  Host.hostIsLetter(c)
}

/// True for any Unicode decimal digit (category Nd).
@pure
@stable(since = "1.0")
pub func isDigit(c: in Char): Bool {
  Host.hostIsDigit(c)
}

/// True for any character that is a Unicode letter or decimal digit.
@pure
@stable(since = "1.0")
pub func isLetterOrDigit(c: in Char): Bool {
  Host.hostIsLetterOrDigit(c)
}

/// True for any Unicode whitespace character (space, tab, newline, …).
@pure
@stable(since = "1.0")
pub func isWhiteSpace(c: in Char): Bool {
  Host.hostIsWhiteSpace(c)
}

/// True for Unicode uppercase letters (category Lu).
@pure
@stable(since = "1.0")
pub func isUpper(c: in Char): Bool {
  Host.hostIsUpper(c)
}

/// True for Unicode lowercase letters (category Ll).
@pure
@stable(since = "1.0")
pub func isLower(c: in Char): Bool {
  Host.hostIsLower(c)
}

/// True for Unicode punctuation characters.
@pure
@stable(since = "1.0")
pub func isPunctuation(c: in Char): Bool {
  Host.hostIsPunctuation(c)
}

/// True for Unicode control characters (C0 + C1 ranges).
@pure
@stable(since = "1.0")
pub func isControl(c: in Char): Bool {
  Host.hostIsControl(c)
}

// =====================================================================
// Case conversion — Unicode-correct (BCL-backed).
// =====================================================================
/// Convert to uppercase using the invariant culture.
@pure
@stable(since = "1.0")
pub func toUpper(c: in Char): Char {
  Host.hostToUpper(c)
}

/// Convert to lowercase using the invariant culture.
@pure
@stable(since = "1.0")
pub func toLower(c: in Char): Char {
  Host.hostToLower(c)
}

// =====================================================================
// Code-point bridge.
// =====================================================================
/// Return the UTF-16 code-unit integer value of `c`.
/// For characters in the BMP this equals the Unicode scalar value.
@pure
@stable(since = "1.0")
pub func toInt(c: in Char): Int {
  Host.hostCharToInt(c)
}

/// Construct a `Char` from a UTF-16 code-unit integer.
/// Panics at runtime when `n` is outside 0..65535.
@pure
@stable(since = "1.0")
pub func fromInt(n: in Int): Char
  requires: n >= 0 and n <= 65535
{
  Host.hostIntToChar(n)
}

// =====================================================================
// ASCII-range helpers — pure Lyric with provable contracts.
// =====================================================================
/// True iff `c` is an ASCII character (code unit 0..127).
@pure
@stable(since = "1.0")
pub func isAscii(c: in Char): Bool {
  Host.hostCharToInt(c) <= 127
}

/// The decimal value of an ASCII digit '0'..'9', or `None` for other chars.
/// Uses integer subtraction so the prover can verify the range directly.
@pure
@stable(since = "1.0")
pub func digitValue(c: in Char): Option[Int] {
  val cp = Host.hostCharToInt(c)
  val zero = Host.hostCharToInt('0')
  val nine = Host.hostCharToInt('9')
  if cp >= zero and cp <= nine {
    Some(value = cp - zero)
  } else {
    None
  }
}

/// The value 0..15 of an ASCII hex digit ('0'..'9', 'a'..'f', 'A'..'F'),
/// or `None` for any other character.
@pure
@stable(since = "1.0")
pub func hexDigitValue(c: in Char): Option[Int] {
  val cp = Host.hostCharToInt(c)
  val zero = Host.hostCharToInt('0')
  val nine = Host.hostCharToInt('9')
  val lowA = Host.hostCharToInt('a')
  val lowF = Host.hostCharToInt('f')
  val upA = Host.hostCharToInt('A')
  val upF = Host.hostCharToInt('F')
  if cp >= zero and cp <= nine {
    Some(value = cp - zero)
  } else if cp >= lowA and cp <= lowF {
    Some(value = cp - lowA + 10)
  } else if cp >= upA and cp <= upF {
    Some(value = cp - upA + 10)
  } else {
    None
  }
}

// =====================================================================
// ASCII fast-path helpers — pure Lyric, no host calls needed.
// These only cover the ASCII range (0..127); for full Unicode correctness
// use the BCL-backed isUpper / isLower / toUpper / toLower above.
// =====================================================================
/// True iff `c` is an ASCII uppercase letter ('A'..'Z').
@pure
@stable(since = "1.0")
pub func isAsciiUpper(c: in Char): Bool {
  val cp = Host.hostCharToInt(c)
  cp >= 65 and cp <= 90
}

/// True iff `c` is an ASCII lowercase letter ('a'..'z').
@pure
@stable(since = "1.0")
pub func isAsciiLower(c: in Char): Bool {
  val cp = Host.hostCharToInt(c)
  cp >= 97 and cp <= 122
}

/// True iff `c` is an ASCII letter ('A'..'Z' or 'a'..'z').
@pure
@stable(since = "1.0")
pub func isAsciiLetter(c: in Char): Bool {
  isAsciiUpper(c) or isAsciiLower(c)
}

/// True iff `c` is an ASCII decimal digit ('0'..'9').
@pure
@stable(since = "1.0")
pub func isAsciiDigit(c: in Char): Bool {
  val cp = Host.hostCharToInt(c)
  cp >= 48 and cp <= 57
}

/// True iff `c` is an ASCII letter or digit.
@pure
@stable(since = "1.0")
pub func isAsciiLetterOrDigit(c: in Char): Bool {
  isAsciiLetter(c) or isAsciiDigit(c)
}

/// True iff `c` is an ASCII whitespace character
/// (space 0x20, tab 0x09, LF 0x0A, VT 0x0B, FF 0x0C, CR 0x0D).
@pure
@stable(since = "1.0")
pub func isAsciiWhiteSpace(c: in Char): Bool {
  val cp = Host.hostCharToInt(c)
  cp == 32 or cp == 9 or cp == 10 or cp == 11 or cp == 12 or cp == 13
}

/// Convert an ASCII uppercase letter to lowercase; other characters
/// are returned unchanged.
@pure
@stable(since = "1.0")
pub func asciiToLower(c: in Char): Char {
  if isAsciiUpper(c) {
    Host.hostIntToChar(Host.hostCharToInt(c) + 32)
  } else {
    c
  }
}

/// Convert an ASCII lowercase letter to uppercase; other characters
/// are returned unchanged.
@pure
@stable(since = "1.0")
pub func asciiToUpper(c: in Char): Char {
  if isAsciiLower(c) {
    Host.hostIntToChar(Host.hostCharToInt(c) - 32)
  } else {
    c
  }
}
