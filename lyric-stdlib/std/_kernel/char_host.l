//! std/_kernel/char_host.l — host boundary for System.Char and System.Convert
//! character operations.
//!
//! Provides Unicode-conformant classification (`IsLetter`, `IsDigit`, …),
//! case conversion (`ToUpper`, `ToLower`), and the char ↔ Int code-point
//! bridge (`Convert.ToInt32(char)` / `Convert.ToChar(int)`).
//!
//! `hostGetNumericValue` (System.Char.GetNumericValue) was deleted on
//! both targets: it had no consumer anywhere in the repo, and dead extern
//! surface is unauditable risk (the Std.IO precedent).  `Std.Char`'s
//! `digitValue` / `hexDigitValue` use integer subtraction for the ASCII
//! ranges they cover.
//!
//! Internal: only `Std.Char` should import this; per
//! `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
@axiom("System.Char and System.Convert character operations conform to their documented .NET contracts")
package Std.CharHost

extern type NetChar = "System.Char"

extern type CharConvert = "System.Convert"

// =====================================================================
// Classification.  Overload scoring binds the (char) overloads exactly
// (each predicate also has a (string, int) form).
// =====================================================================
pub func hostIsLetter(c: in Char): Bool {
  NetChar.IsLetter(c)
}

pub func hostIsDigit(c: in Char): Bool {
  NetChar.IsDigit(c)
}

pub func hostIsLetterOrDigit(c: in Char): Bool {
  NetChar.IsLetterOrDigit(c)
}

// `hostIsWhiteSpace` was removed: `Std.Char.isWhiteSpace` is now a pure-Lyric
// canonical Unicode White_Space test (see char.l), because the .NET and JVM
// host predicates disagreed on U+00A0 / U+2007 / U+202F (#5501).
pub func hostIsUpper(c: in Char): Bool {
  NetChar.IsUpper(c)
}

pub func hostIsLower(c: in Char): Bool {
  NetChar.IsLower(c)
}

pub func hostIsPunctuation(c: in Char): Bool {
  NetChar.IsPunctuation(c)
}

pub func hostIsControl(c: in Char): Bool {
  NetChar.IsControl(c)
}

// =====================================================================
// Case conversion.  NOTE: `Char.ToUpper(char)`/`ToLower(char)` use the
// CURRENT culture (the invariant variants are `To*Invariant`), while the
// JVM twin's `Character.to*Case` is locale-independent — a documented
// cross-target casing-parity gap for culture-sensitive code points
// (e.g. Turkish dotless I), tracked in #5557.
// =====================================================================
pub func hostToUpper(c: in Char): Char {
  NetChar.ToUpper(c)
}

pub func hostToLower(c: in Char): Char {
  NetChar.ToLower(c)
}

// =====================================================================
// Code-point bridge.
// =====================================================================
// Return the UTF-16 code-unit value of `c` as an Int.
// `System.Convert.ToInt32(char)` is the canonical overload; scoring
// binds it exactly among Convert.ToInt32's overload set.
pub func hostCharToInt(c: in Char): Int {
  CharConvert.ToInt32(c)
}

// Convert an integer code-unit value back to a Char.
// Throws `System.OverflowException` for values outside 0..65535.
pub func hostIntToChar(n: in Int): Char {
  CharConvert.ToChar(n)
}
