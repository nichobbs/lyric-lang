//! std/_kernel_jvm/char_host.l — JVM host boundary for java.lang.Character
//! and related character operations.
//!
//! Mirrors _kernel/char_host.l.  Pure JDK bindings — the previous version
//! routed four operations through a phantom `lyric.stdlib.jvm.CharHost`
//! class that never existed at runtime (same elimination as the
//! file/console/math/uuid kernel rewrites, D-progress-555):
//!
//!   isPunctuation — absent from java.lang.Character; a pure body checks
//!                   Character.getType() against the seven Unicode
//!                   punctuation categories (matching System.Char).
//!   charToInt     — the (int) c widening cast has no JDK method form;
//!                   Character.hashCode(char) is documented to return the
//!                   char value itself.
//!   intToChar     — the (char) n narrowing cast likewise;
//!                   Character.toString(int) + charAt(0) round-trips the
//!                   BMP code points Lyric Char covers.
//!   getNumericValue — DELETED on both targets: no consumer anywhere in
//!                   the repo (dead extern surface is unauditable risk,
//!                   the Std.IO precedent).
//!
//! Java spells several method names differently from .NET:
//!   isWhitespace (not isWhiteSpace), isUpperCase (not isUpper),
//!   isLowerCase (not isLower), isISOControl (not isControl),
//!   toUpperCase / toLowerCase.
//!
//! Internal: only Std.Char should import this.
@axiom("java.lang.Character character operations conform to their documented JVM contracts")
package Std.CharHost

// =====================================================================
// Classification.
// =====================================================================
@externTarget("java.lang.Character.isLetter")
pub func hostIsLetter(c: in Char): Bool = ()

@externTarget("java.lang.Character.isDigit")
pub func hostIsDigit(c: in Char): Bool = ()

@externTarget("java.lang.Character.isLetterOrDigit")
pub func hostIsLetterOrDigit(c: in Char): Bool = ()

// Java spells this isWhitespace, not isWhiteSpace.
@externTarget("java.lang.Character.isWhitespace")
pub func hostIsWhiteSpace(c: in Char): Bool = ()

// Java spells this isUpperCase, not isUpper.
@externTarget("java.lang.Character.isUpperCase")
pub func hostIsUpper(c: in Char): Bool = ()

// Java spells this isLowerCase, not isLower.
@externTarget("java.lang.Character.isLowerCase")
pub func hostIsLower(c: in Char): Bool = ()

// No isPunctuation in java.lang.Character: check getType() against the
// seven Unicode punctuation categories (Pc/Pd/Ps/Pe/Pi/Pf/Po), matching
// System.Char.IsPunctuation.  Category ordinals per java.lang.Character:
// DASH_PUNCTUATION=20, START_PUNCTUATION=21, END_PUNCTUATION=22,
// CONNECTOR_PUNCTUATION=23, OTHER_PUNCTUATION=24,
// INITIAL_QUOTE_PUNCTUATION=29, FINAL_QUOTE_PUNCTUATION=30.
pub func hostIsPunctuation(c: in Char): Bool {
  val t = hostGetType(c)
  t == 20 or t == 21 or t == 22 or t == 23 or t == 24 or t == 29 or t == 30
}

@externTarget("java.lang.Character.getType")
func hostGetType(c: in Char): Int = ()

// Java spells this isISOControl, not isControl.
@externTarget("java.lang.Character.isISOControl")
pub func hostIsControl(c: in Char): Bool = ()

// =====================================================================
// Case conversion.
// =====================================================================
// Java spells this toUpperCase, not toUpper.
@externTarget("java.lang.Character.toUpperCase")
pub func hostToUpper(c: in Char): Char = ()

// Java spells this toLowerCase, not toLower.
@externTarget("java.lang.Character.toLowerCase")
pub func hostToLower(c: in Char): Char = ()

// =====================================================================
// Code-point bridge.  The JDK has no method form of the (int) c / (char) n
// casts; Character.hashCode(char) is documented to return the char value
// itself, and Character.toString(int) + String.charAt(0) round-trips the
// BMP code points Lyric Char covers.
// =====================================================================
@externTarget("java.lang.Character.hashCode")
pub func hostCharToInt(c: in Char): Int = ()

extern type JCharSeq = "java.lang.Character"

pub func hostIntToChar(n: in Int): Char {
  val s = JCharSeq.toString(n)
  s.charAt(0)
}
