//! std/_kernel_jvm/unicode_host.l — JVM host boundary for Unicode category lookup.
//!
//! Mirrors _kernel/unicode_host.l for the JVM target.  Pure Lyric over JVM
//! auto-FFI against `java.lang.Character.getType(int)`, replacing a
//! `lyric.stdlib.jvm.UnicodeHost` shim class that never existed at runtime
//! (the `extern package` mechanism it used is a no-op in both the type
//! checker and both codegens -- same elimination as the console_host.l /
//! time_host.l / collections_host.l / file_host.l rewrites).
//!
//! `Character.getType` returns Java's own category constants, which use a
//! DIFFERENT integer numbering than .NET's `System.Globalization.
//! UnicodeCategory` this kernel must produce (matching `_kernel/
//! unicode_host.l`'s convention, so the self-hosted lexer stays
//! target-agnostic).  Both platforms' constants are independent orderings
//! of the same underlying Unicode General_Category property, so
//! `jvmCategoryToNetConvention` below cross-references via the standard
//! General_Category abbreviation for each value (verified against the
//! documented `java.lang.Character` category-constant values and the
//! documented `System.Globalization.UnicodeCategory` enum ordinals).
//!
//! Internal: only Lyric.Lexer should import this; per the kernel cap rule,
//! every extern here counts toward the kernel budget.
@axiom("java.lang.Character.getType conforms to its documented JVM contract; jvmCategoryToNetConvention correctly cross-references it to the .NET UnicodeCategory convention via Unicode General_Category")
package Std.UnicodeHost

extern type JCharacter = "java.lang.Character"

// Cross-references a Java `Character.getType` category int to the .NET
// `UnicodeCategory` ordinal for the same Unicode General_Category value.
// Table (Gc = General_Category abbreviation, Java = Character.* constant
// value, Net = UnicodeCategory enum ordinal):
//   Gc  Java  Net    Gc  Java  Net    Gc  Java  Net
//   Cn   0    29     Cc  15    14     Pd  20    19
//   Lu   1    0      Cf  16    15     Ps  21    20
//   Ll   2    1      Co  18    17     Pe  22    21
//   Lt   3    2      Cs  19    16     Pc  23    18
//   Lm   4    3      Pi  29    22     Po  24    24
//   Lo   5    4      Pf  30    23     Sm  25    25
//   Mn   6    5                       Sc  26    26
//   Me   7    7                       Sk  27    27
//   Mc   8    6                       So  28    28
//   Nd   9    8
//   Nl  10    9
//   No  11   10
//   Zs  12   11
//   Zl  13   12
//   Zp  14   13
// (Java category 17 is unassigned/reserved — no Character.* constant uses it.)
func jvmCategoryToNetConvention(javaCategory: in Int): Int {
  match javaCategory {
    case 0 -> 29
    case 1 -> 0
    case 2 -> 1
    case 3 -> 2
    case 4 -> 3
    case 5 -> 4
    case 6 -> 5
    case 7 -> 7
    case 8 -> 6
    case 9 -> 8
    case 10 -> 9
    case 11 -> 10
    case 12 -> 11
    case 13 -> 12
    case 14 -> 13
    case 15 -> 14
    case 16 -> 15
    case 18 -> 17
    case 19 -> 16
    case 20 -> 19
    case 21 -> 20
    case 22 -> 21
    case 23 -> 18
    case 24 -> 24
    case 25 -> 25
    case 26 -> 26
    case 27 -> 27
    case 28 -> 28
    case 29 -> 22
    case 30 -> 23
    case _ -> 29
  }
}

pub func hostUnicodeCategory(c: in Char): Int {
  jvmCategoryToNetConvention(JCharacter.getType(c.toInt()))
}

// `UnicodeCategory` constants — same values as _kernel/unicode_host.l so
// Lyric.Lexer can remain target-agnostic.
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
