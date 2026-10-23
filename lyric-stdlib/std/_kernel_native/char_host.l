//! std/_kernel_native/char_host.l — native-target host boundary for
//! character operations.
//!
//! The `--target native` twin of `_kernel/char_host.l` (`.NET`,
//! `System.Char`/`System.Convert`-backed) and `_kernel_jvm/char_host.l`
//! (`java.lang.Character`-backed), selected by the native source loader by
//! basename (issue #6811, gating N9.5/N9.6's h2 stack — `Std.HttpEngine.
//! Hpack`'s Huffman codec calls `Std.Char`'s char<->int bridge).
//!
//! Code-point bridge: `Char` and `Int` are BOTH lowered to `i32` on native
//! (`native/plan/03-type-mapping.md`), so unlike the BCL/JDK twins (which
//! need a real conversion call — `Convert.ToInt32`/`ToChar`,
//! `Character.hashCode`/`toString`), the bridge here is the same identity
//! bitcast the numeric-conversion builtin methods (`.toInt()`/`.toChar()`,
//! `Lyric.LlvmCodegen`'s `numericConvTarget`, #1901) already lower to.  No
//! `extern func` is needed for it.
//!
//! Classification / case conversion: lyric-rt's Unicode general-category
//! table (generated from UnicodeData.txt by
//! `scripts/gen_unicode_category_tables.py`, issue #6858) answers the
//! predicates by category, as `System.Char` and `java.lang.Character` do
//! (letter = Lu/Ll/Lt/Lm/Lo, digit = Nd, upper = Lu, lower = Ll,
//! punctuation = P*, control = Cc), for every code point including the
//! supplementary planes; case conversion is the simple one-to-one mapping
//! `.toLower()`/`.toUpper()` on a `String` use, so a `Char` and a one-character
//! `String` agree.  No locale rule applies (no Turkish dotless I), and a code
//! point with no mapping is returned unchanged.  Unassigned and surrogate
//! code points are in no class.
//!
//! Internal: only `Std.Char` should import this; per
//! `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
@axiom("Char and Int share the i32 native representation, so the code-point bridge is a lossless identity; lyric_char_is_* and lyric_char_to_* answer from the Unicode general-category and simple case-mapping tables per their lyric_rt.h contract")
@pure
package Std.CharHost

// =====================================================================
// Code-point bridge. Char and Int are both i32 on native — see file
// header. `.toInt()`/`.toChar()` are the numeric-conversion builtin
// methods (#1901); no extern call is needed or possible here (there is
// no BCL/JDK to bridge to).
// =====================================================================
pub func hostCharToInt(c: in Char): Int {
  c.toInt()
}

// Range validation (0..65535) is the caller's job — `Std.Char.fromInt`
// already `requires:` it before reaching here, matching the .NET twin's
// `Convert.ToChar` overflow contract.
pub func hostIntToChar(n: in Int): Char {
  n.toChar()
}

// =====================================================================
// Classification and case conversion by Unicode general category and
// simple case mapping, over lyric-rt (see file header, #6858).
// =====================================================================
extern func rtIsLetter(cp: Int): Int = "lyric_char_is_letter"

extern func rtIsDigit(cp: Int): Int = "lyric_char_is_digit"

extern func rtIsUpper(cp: Int): Int = "lyric_char_is_upper"

extern func rtIsLower(cp: Int): Int = "lyric_char_is_lower"

extern func rtIsPunctuation(cp: Int): Int = "lyric_char_is_punctuation"

extern func rtIsControl(cp: Int): Int = "lyric_char_is_control"

extern func rtToUpper(cp: Int): Int = "lyric_char_to_upper"

extern func rtToLower(cp: Int): Int = "lyric_char_to_lower"

pub func hostIsLetter(c: in Char): Bool {
  rtIsLetter(hostCharToInt(c)) != 0
}

pub func hostIsDigit(c: in Char): Bool {
  rtIsDigit(hostCharToInt(c)) != 0
}

pub func hostIsLetterOrDigit(c: in Char): Bool {
  hostIsLetter(c) or hostIsDigit(c)
}

// `hostIsWhiteSpace` is intentionally absent here too — see `_kernel/
// char_host.l`'s note: `Std.Char.isWhiteSpace` is pure-Lyric cross-target
// (#5501) and never calls into `Std.CharHost` on any target.
pub func hostIsUpper(c: in Char): Bool {
  rtIsUpper(hostCharToInt(c)) != 0
}

pub func hostIsLower(c: in Char): Bool {
  rtIsLower(hostCharToInt(c)) != 0
}

pub func hostIsPunctuation(c: in Char): Bool {
  rtIsPunctuation(hostCharToInt(c)) != 0
}

pub func hostIsControl(c: in Char): Bool {
  rtIsControl(hostCharToInt(c)) != 0
}

pub func hostToUpper(c: in Char): Char {
  hostIntToChar(rtToUpper(hostCharToInt(c)))
}

pub func hostToLower(c: in Char): Char {
  hostIntToChar(rtToLower(hostCharToInt(c)))
}
