//! std/_kernel_jvm/char_host.l — JVM host boundary for java.lang.Character
//! and related character operations.
//!
//! Mirrors _kernel/char_host.l.  Most operations route directly to
//! java.lang.Character static methods.  Four require lyric.stdlib.jvm.CharHost
//! shims because the JVM API differs:
//!
//!   isPunctuation — absent from java.lang.Character; shim checks
//!                   Character.getType() against CONNECTOR_PUNCTUATION,
//!                   DASH_PUNCTUATION, END_PUNCTUATION, FINAL_QUOTE_PUNCTUATION,
//!                   INITIAL_QUOTE_PUNCTUATION, OTHER_PUNCTUATION,
//!                   START_PUNCTUATION.
//!   charToInt     — Java widening cast `(int) c`; shim wraps the cast.
//!   intToChar     — Java narrowing cast `(char) n`; shim wraps the cast.
//!   getNumericValue — Java returns `int` (-1 when absent); shim casts
//!                   to `double` to match the .NET `double` signature.
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

// No isPunctuation in java.lang.Character; shim checks getType() categories.
@externTarget("lyric.stdlib.jvm.CharHost.isPunctuation")
pub func hostIsPunctuation(c: in Char): Bool = ()

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
// Code-point bridge.
// =====================================================================
// Shim: (int) c widening cast.
@externTarget("lyric.stdlib.jvm.CharHost.charToInt")
pub func hostCharToInt(c: in Char): Int = ()

// Shim: (char) n narrowing cast.
@externTarget("lyric.stdlib.jvm.CharHost.intToChar")
pub func hostIntToChar(n: in Int): Char = ()

// =====================================================================
// Numeric value (Unicode).
// =====================================================================
// Java getNumericValue returns int; shim casts to double.
@externTarget("lyric.stdlib.jvm.CharHost.getNumericValue")
pub func hostGetNumericValue(c: in Char): Double = ()
