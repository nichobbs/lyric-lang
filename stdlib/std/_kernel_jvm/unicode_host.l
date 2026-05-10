// std/_kernel_jvm/unicode_host.l — JVM host boundary for Unicode category lookup.
//
// Mirrors _kernel/unicode_host.l for the JVM target.  Routes through
// java.lang.Character.getType(int), which returns the Unicode general
// category as an int whose values match the JVM's Character constants.
//
// The return values of java.lang.Character.getType differ in integer
// values from .NET's System.Globalization.UnicodeCategory.  The
// lyric.stdlib.jvm.UnicodeHost shim translates JVM category ints to
// the same convention used by the .NET kernel so that the self-hosted
// lexer (Lyric.Lexer, which imports Std.UnicodeHost) is target-agnostic.
//
// Mapping convention (matches _kernel/unicode_host.l constants):
//   0  = UppercaseLetter  (Character.UPPERCASE_LETTER = 1 → mapped to 0)
//   1  = LowercaseLetter  (Character.LOWERCASE_LETTER = 2 → mapped to 1)
//   ...see lyric.stdlib.jvm.UnicodeHost.getCategory for the full table.
//
// Internal: only Lyric.Lexer should import this; per the kernel cap rule,
// every extern here counts toward the kernel budget.

@axiom("lyric.stdlib.jvm.UnicodeHost correctly maps java.lang.Character.getType to the .NET UnicodeCategory convention")
package Std.UnicodeHost

extern package lyric.stdlib.jvm.UnicodeHost {
  // Return the .NET-convention UnicodeCategory integer for code-point `cp`.
  // The shim calls Character.getType(cp) and translates to the .NET ordinals
  // expected by the Lyric lexer.
  pub func getCategory(cp: in Int): Int
}

pub func hostUnicodeCategory(c: in Char): Int =
  lyric.stdlib.jvm.UnicodeHost.getCategory(charToInt(c))

// `UnicodeCategory` constants — same values as _kernel/unicode_host.l so
// Lyric.Lexer can remain target-agnostic.
@pure pub func ucUppercaseLetter():       Int { 0 }
@pure pub func ucLowercaseLetter():       Int { 1 }
@pure pub func ucTitlecaseLetter():       Int { 2 }
@pure pub func ucModifierLetter():        Int { 3 }
@pure pub func ucOtherLetter():           Int { 4 }
@pure pub func ucNonSpacingMark():        Int { 5 }
@pure pub func ucSpacingCombiningMark():  Int { 6 }
@pure pub func ucDecimalDigitNumber():    Int { 8 }
@pure pub func ucLetterNumber():          Int { 9 }
@pure pub func ucConnectorPunctuation():  Int { 18 }
