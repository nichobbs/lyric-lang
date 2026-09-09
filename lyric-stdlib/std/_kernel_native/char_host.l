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
//! Classification / case conversion: `lyric-rt` has no ICU or Unicode
//! general-category table (docs/57 §"stdlib core-I/O test gaps" catalogues
//! this class of gap; see also the self-hosted lexer's own
//! `Std.UnicodeHost`, which is `.NET`-only and has no native use). Building
//! one is a substantial undertaking on its own — full Unicode general
//! categories span most of the Basic Multilingual Plane and several
//! supplementary planes. Per this issue's own "suggested fix" and this
//! repo's "smaller, fully-finished slice" standard, this file ships the
//! ASCII-range slice (all `Std.HttpEngine.Hpack`'s Huffman codec and every
//! other currently-shipping native consumer actually needs) as a
//! genuinely complete, pure-Lyric implementation with NO extern/libc
//! dependency (avoids locale/platform divergence entirely) — every
//! predicate below matches `System.Char`'s Unicode-category-based verdict
//! exactly for the U+0000..U+007F range. Code points above U+007F fall
//! through to the conservative default appropriate to each predicate
//! (`false` for the "is-X" predicates, `false` for `isControl` above the
//! ASCII C0 set + DEL, identity for the case-conversion functions) —
//! a real, tracked, dated cross-target parity gap: full non-ASCII Unicode
//! classification on `--target native` is issue #6858.
//!
//! Internal: only `Std.Char` should import this; per
//! `compiler/lyric/std/_kernel/README.md` the kernel is the audited
//! extern boundary, not a general-purpose API.
@axiom("Char and Int share the i32 native representation, so the code-point bridge is a lossless identity; ASCII-range classification below matches System.Char's Unicode-category verdicts for U+0000..U+007F")
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
// Classification — ASCII-range (U+0000..U+007F), matching System.Char's
// Unicode-category verdict exactly in that range. See file header for the
// non-ASCII gap (#6858).
// =====================================================================
pub func hostIsLetter(c: in Char): Bool {
  val cp = hostCharToInt(c);
  (cp >= 65 and cp <= 90) or (cp >= 97 and cp <= 122)
}

pub func hostIsDigit(c: in Char): Bool {
  val cp = hostCharToInt(c)
  cp >= 48 and cp <= 57
}

pub func hostIsLetterOrDigit(c: in Char): Bool {
  hostIsLetter(c) or hostIsDigit(c)
}

// `hostIsWhiteSpace` is intentionally absent here too — see `_kernel/
// char_host.l`'s note: `Std.Char.isWhiteSpace` is pure-Lyric cross-target
// (#5501) and never calls into `Std.CharHost` on any target.
pub func hostIsUpper(c: in Char): Bool {
  val cp = hostCharToInt(c)
  cp >= 65 and cp <= 90
}

pub func hostIsLower(c: in Char): Bool {
  val cp = hostCharToInt(c)
  cp >= 97 and cp <= 122
}

// Unicode general categories Pc/Pd/Ps/Pe/Pi/Pf/Po within ASCII:
// ! " # % & ' ( ) * , - . / : ; ? @ [ \ ] _ { }
// (deliberately excludes the ASCII symbol categories Sm/Sc/Sk:
// $ + < = > ^ ` | ~ are NOT punctuation, matching System.Char.IsPunctuation
// / java.lang.Character's Unicode-category check.)
pub func hostIsPunctuation(c: in Char): Bool {
  val cp = hostCharToInt(c);
  (cp >= 33 and cp <= 35) or
    // ! " #
    cp == 37 or
    cp == 38 or
    // % &
    (cp >= 39 and cp <= 42) or
    // ' ( ) *
    (cp >= 44 and cp <= 47) or
    // , - . /
    (cp >= 58 and cp <= 59) or
    // : ;
    cp == 63 or
    cp == 64 or
    // ? @
    (cp >= 91 and cp <= 93) or
    // [ \ ]
    cp == 95 or
    // _
    cp == 123 or
    cp == 125         // { }  ( | at 124 is Sm, not punctuation)
}

// ASCII C0 control codes (U+0000..U+001F) plus DEL (U+007F). The C1
// control range (U+0080..U+009F) is non-ASCII and out of this slice's
// scope (#6858).
pub func hostIsControl(c: in Char): Bool {
  val cp = hostCharToInt(c);
  (cp >= 0 and cp <= 31) or cp == 127
}

// =====================================================================
// Case conversion — ASCII-range; every other code point (including the
// full non-ASCII Unicode general case, #6858) is returned unchanged,
// matching `Char.ToUpper`/`ToLower`'s behavior for code points that have
// no case mapping.
// =====================================================================
pub func hostToUpper(c: in Char): Char {
  val cp = hostCharToInt(c)
  if cp >= 97 and cp <= 122 {
    hostIntToChar(cp - 32)
  } else {
    c
  }
}

pub func hostToLower(c: in Char): Char {
  val cp = hostCharToInt(c)
  if cp >= 65 and cp <= 90 {
    hostIntToChar(cp + 32)
  } else {
    c
  }
}
