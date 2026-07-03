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

// =====================================================================
// Classification.
// =====================================================================
@externTarget("System.Char.IsLetter")
pub func hostIsLetter(c: in Char): Bool = ()

@externTarget("System.Char.IsDigit")
pub func hostIsDigit(c: in Char): Bool = ()

@externTarget("System.Char.IsLetterOrDigit")
pub func hostIsLetterOrDigit(c: in Char): Bool = ()

@externTarget("System.Char.IsWhiteSpace")
pub func hostIsWhiteSpace(c: in Char): Bool = ()

@externTarget("System.Char.IsUpper")
pub func hostIsUpper(c: in Char): Bool = ()

@externTarget("System.Char.IsLower")
pub func hostIsLower(c: in Char): Bool = ()

@externTarget("System.Char.IsPunctuation")
pub func hostIsPunctuation(c: in Char): Bool = ()

@externTarget("System.Char.IsControl")
pub func hostIsControl(c: in Char): Bool = ()

// =====================================================================
// Case conversion.
// =====================================================================
@externTarget("System.Char.ToUpper")
pub func hostToUpper(c: in Char): Char = ()

@externTarget("System.Char.ToLower")
pub func hostToLower(c: in Char): Char = ()

// =====================================================================
// Code-point bridge.
// =====================================================================
// Return the UTF-16 code-unit value of `c` as an Int.
// `System.Convert.ToInt32(char)` is the canonical overload.
@externTarget("System.Convert.ToInt32")
pub func hostCharToInt(c: in Char): Int = ()

// Convert an integer code-unit value back to a Char.
// Throws `System.OverflowException` for values outside 0..65535.
@externTarget("System.Convert.ToChar")
pub func hostIntToChar(n: in Int): Char = ()
