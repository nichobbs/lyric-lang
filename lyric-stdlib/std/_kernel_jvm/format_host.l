//! std/_kernel_jvm/format_host.l — JVM host boundary for number and string
//! formatting.
//!
//! Mirrors _kernel/format_host.l: exports the same three-function surface
//! (`hostInvariantCulture` / `hostIntToString` / `hostDoubleToString`) that
//! std/format.l consumes.  Pure Lyric over real JDK classes via the JVM
//! auto-FFI — the previous version exported an obsolete surface
//! (`hostToHexString` / `hostFormatFixed`) routed through a phantom
//! `lyric.stdlib.jvm.FormatHost` class that never existed at runtime, which
//! left Std.Format non-functional on this target (docs/59 F-1a).
//!
//! The JDK has no BCL-format-string interpreter, so the format strings the
//! .NET twin hands to `Int32.ToString(string)` / `Double.ToString(string,
//! IFormatProvider)` are interpreted here over JDK primitives, matching the
//! .NET invariant-culture output (verified value-by-value against a
//! `--target dotnet` run of the same inputs):
//!
//!   Int    "x"/"X" (+ optional precision) — Integer.toHexString two's-
//!          complement hex, zero-padded to the precision; "d"/"D" (+
//!          optional precision) — decimal, zero-padded after the sign;
//!          "g"/"G"/"" — plain decimal.
//!   Double "F<n>" (default n = 2) — fixed-point over the double's EXACT
//!          binary value with round-half-to-even (BigDecimal(double) +
//!          RoundingMode.HALF_EVEN — both .NET-verified: 0.5→"0", 2.5→"2",
//!          0.125→"0.12", 2.675→"2.67"), negative zero and negative values
//!          that round to zero keep their "-" sign, and the non-finite
//!          spellings are the .NET invariant symbols "NaN" / "Infinity" /
//!          "-Infinity".
//!
//! Any other format specifier panics with a clear message rather than
//! guessing — the kernel contract is exactly what std/format.l needs, and a
//! silent wrong answer on an unsupported BCL specifier would be a
//! cross-target divergence.
//!
//! `CultureInfo` maps to java.util.Locale; the invariant culture is
//! Locale.ROOT.  BigDecimal.toPlainString always renders "." as the decimal
//! separator, so the culture argument needs no further plumbing: the only
//! obtainable value on this target is the invariant one.
//!
//! Internal: only Std.Format should import this.
@axiom("java.math.BigDecimal, java.lang.Integer, and java.util.Locale conform to their documented JVM contracts")
package Std.FormatHost

extern type CultureInfo = "java.util.Locale"

extern type JBigDecimal = "java.math.BigDecimal"

extern type JRoundingMode = "java.math.RoundingMode"

extern type JInteger = "java.lang.Integer"

// =====================================================================
// Culture singleton.
// =====================================================================
// java.util.Locale.ROOT (static field) — the locale-neutral locale, the
// JDK analog of System.Globalization.CultureInfo.InvariantCulture.
@externTarget("java.util.Locale.ROOT")
pub func hostInvariantCulture(): CultureInfo = ()

// =====================================================================
// Integer formatting.
// =====================================================================
@externTarget("java.lang.Integer.toHexString")
func jdkToHexString(n: in Int): String = ()

// BCL-format-specifier precision digits (`"x8"` → 8, `"D5"` → 5); -1 when
// absent.  Panics on a malformed specifier tail so unsupported formats fail
// loud instead of silently diverging from the .NET twin.
func formatPrecision(fmt: in String): Int {
  if fmt.length <= 1 {
    return 0 - 1
  }
  var v = 0
  var i = 1
  while i < fmt.length {
    val c = fmt[i]
    if c < '0' or c > '9' {
      panic(
        "Std.FormatHost (JVM): malformed format specifier \"" + fmt +
          "\" — expected optional decimal precision digits after the specifier letter"
      )
    }
    v = v * 10 + (c.toInt() - 48)
    i += 1
  }
  v
}

// Left-pad `s` with zeros to at least `width` characters; `width` <= 0 or
// shorter-than-s is the identity (matching BCL precision semantics).
func zeroPadTo(s: in String, width: in Int): String {
  var pad = ""
  var need = width - s.length
  while need > 0 {
    pad = pad + "0"
    need = need - 1
  }
  pad + s
}

// Uppercase the ASCII hex digits a-f.  Hex output contains only 0-9/a-f, so
// a full toUpper pass over arbitrary text is unnecessary.
func hexUpper(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = s[i]
    if c >= 'a' and c <= 'f' {
      acc = acc + ("" + hexUpperChar(c))
    } else {
      acc = acc + ("" + c)
    }
    i += 1
  }
  acc
}

func hexUpperChar(c: in Char): Char {
  if c == 'a' {
    'A'
  } else if c == 'b' {
    'B'
  } else if c == 'c' {
    'C'
  } else if c == 'd' {
    'D'
  } else if c == 'e' {
    'E'
  } else {
    'F'
  }
}

/// Format an Int using a BCL format string.  Supported: "x"/"X" (two's-
/// complement hex + optional zero-pad precision), "d"/"D" (decimal +
/// optional zero-pad precision), "g"/"G"/"" (plain decimal).  Matches
/// System.Int32.ToString(string) for these specifiers; any other specifier
/// panics.
pub func hostIntToString(n: in Int, fmt: in String): String {
  if fmt.length == 0 {
    return "" + n
  }
  val spec = fmt[0]
  if spec == 'x' {
    return zeroPadTo(jdkToHexString(n), formatPrecision(fmt))
  }
  if spec == 'X' {
    return zeroPadTo(hexUpper(jdkToHexString(n)), formatPrecision(fmt))
  }
  if spec == 'd' or spec == 'D' {
    val precision = formatPrecision(fmt)
    if n < 0 {
      // Render the magnitude via Integer.toString(n, 10) semantics on the
      // negative value to survive Int.MinValue (whose magnitude overflows),
      // then re-split: "" + n is "-<digits>", pad the digits only.
      val whole = "" + n
      val digits = whole.substring(1, whole.length - 1)
      return "-" + zeroPadTo(digits, precision)
    }
    return zeroPadTo("" + n, precision)
  }
  if spec == 'g' or spec == 'G' {
    if fmt.length == 1 {
      return "" + n
    }
  }
  panic(
    "Std.FormatHost (JVM): unsupported Int format specifier \"" + fmt +
      "\" — supported: x, X, d, D (each with optional precision), g, G"
  )
}

// =====================================================================
// Double formatting.
// =====================================================================
/// Format a Double using a BCL format string and culture.  Supported:
/// "F<n>" / "f<n>" (fixed-point, default 2 decimals) with the invariant
/// culture; matches System.Double.ToString(string, IFormatProvider) for
/// that specifier (round-half-to-even over the exact binary value,
/// sign-preserving for negative zero, "NaN"/"Infinity"/"-Infinity"
/// non-finite spellings).  Any other specifier panics.
pub func hostDoubleToString(x: in Double, fmt: in String, culture: in CultureInfo): String {
  if fmt.length == 0 or (fmt[0] != 'F' and fmt[0] != 'f') {
    panic(
      "Std.FormatHost (JVM): unsupported Double format specifier \"" + fmt + "\" — supported: F/f with optional precision"
    )
  }
  if x != x {
    return "NaN"
  }
  if x == 1.0 / 0.0 {
    return "Infinity"
  }
  if x == (0.0 - 1.0) / 0.0 {
    return "-Infinity"
  }
  var decimals = formatPrecision(fmt)
  if decimals < 0 {
    // .NET default precision for "F" is NumberFormatInfo.NumberDecimalDigits = 2.
    decimals = 2
  }
  val bd = JBigDecimal.new(x)
  val mode = JRoundingMode.HALF_EVEN
  val scaled = bd.setScale(decimals, mode)
  val s = scaled.toPlainString()
  // BigDecimal has no negative zero and drops the sign of any negative value
  // that rounds to zero; .NET keeps it ((-0.0)→"-0.00", (-0.4)→"F0"→"-0").
  val negative = x < 0.0 or (x == 0.0 and 1.0 / x < 0.0)
  if negative and s[0] != '-' {
    return "-" + s
  }
  s
}
