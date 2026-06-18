//! std/_kernel/unicode_host.l — host boundary for `System.Char`
//! Unicode category lookup.
//!
//! Phase 5 §M5.1 stage 4: the self-hosted lexer
//! (`compiler/lyric/lyric/lexer.l`) needs UAX #31 XID_Start /
//! XID_Continue category coverage for non-ASCII identifier
//! characters.  The .NET BCL exposes the Unicode general category as
//! `System.Globalization.UnicodeCategory`, an `enum : int` with 30
//! values (0..29).  At the IL level the enum value is just an
//! `int32`; we declare the extern as returning `Int` so the lexer
//! can compare against integer constants without round-tripping
//! through Lyric's enum machinery.  The constants below mirror
//! `System.Globalization.UnicodeCategory` member ordering.
//!
//! Internal: only the self-hosted `Lyric.Lexer` should import this;
//! per `compiler/lyric/std/_kernel/README.md` the kernel is the
//! audited extern boundary, not a general-purpose API.
@axiom("System.Char.GetUnicodeCategory returns System.Globalization.UnicodeCategory whose underlying type is int32")
package Std.UnicodeHost

@externTarget("System.Char.GetUnicodeCategory")
pub func hostUnicodeCategory(c: in Char): Int = ()

// `UnicodeCategory` enum constants (numeric values), kept here so
// callers don't have to memorise them.  These match the .NET enum
// definition and are stable across runtime versions.
@pure
pub func ucUppercaseLetter(): Int {
  0
}

@pure
pub func ucLowercaseLetter(): Int {
  1
}

@pure
pub func ucTitlecaseLetter(): Int {
  2
}

@pure
pub func ucModifierLetter(): Int {
  3
}

@pure
pub func ucOtherLetter(): Int {
  4
}

@pure
pub func ucNonSpacingMark(): Int {
  5
}

@pure
pub func ucSpacingCombiningMark(): Int {
  6
}

@pure
pub func ucDecimalDigitNumber(): Int {
  8
}

@pure
pub func ucLetterNumber(): Int {
  9
}

@pure
pub func ucConnectorPunctuation(): Int {
  18
}
