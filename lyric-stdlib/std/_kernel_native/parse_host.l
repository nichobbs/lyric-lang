//! std/_kernel_native/parse_host.l - native host boundary for primitive
//! parsing: the `--target native` twin of `_kernel/parse_host.l` (.NET) and
//! `_kernel_jvm/parse_host.l`.
//!
//! Int and Long parsing are pure Lyric in stdlib/std/parse.l; only Double and
//! Bool cross the boundary here, on the same target-neutral two-argument
//! surface the other twins export.
//!
//! Double parsing accepts exactly what the .NET kernel's invariant-culture
//! `Double.TryParse(NumberStyles.Float)` does, so a string that fails on one
//! target fails on all: surrounding whitespace, an optional sign, decimal
//! digits with at most one '.', an optional `[eE][+-]?digits` exponent, and
//! the words "NaN" and "Infinity".  The syntax is checked in Lyric first and
//! only then handed to libc `strtod`, which on its own would also accept
//! hexadecimal floats ("0x1p3"), "inf"/"nan" spellings and a trailing garbage
//! run.  Process locale is never set, so `strtod` reads '.' as the decimal
//! point.  A value too large for a double parses to infinity, as on the other
//! targets.
//!
//! Internal: only Std.Parse should import this.
@axiom("libc strtod(3) conforms to its documented C99 contract; lyric_string_to_cstring/lyric_cstring_free are the runtime's NUL-terminated copy and its release")
@pure
package Std.ParseHost

import Std.Core
import Std.String as Str

extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

extern func freeC(p: NativePtr[Byte]): Unit = "lyric_cstring_free"

extern func cStrtod(s: NativePtr[Byte], end: NativePtr[Byte]): Double = "strtod"

pub func hostTryParseDouble(s: in String, value: out Double): Bool {
  value = 0.0
  val t = Str.trim(s)
  if t.length == 0 {
    return false
  }
  if not isDecimalFloat(t) {
    return false
  }
  value = strtodChecked(t)
  true
}

@unsafe_ffi
func strtodChecked(t: in String): Double {
  val c = toC(t)
  val v = cStrtod(c, nativeNullPtr())
  freeC(c)
  v
}

// The grammar `Double.TryParse(NumberStyles.Float)` accepts once surrounding
// whitespace is trimmed: an optional sign, then "NaN", "Infinity", or digits
// with at most one '.' (at least one digit in total) and an optional exponent
// `[eE][+-]?digits`.  `t` is already trimmed.
func isDecimalFloat(t: in String): Bool {
  val n = t.length
  var i = 0
  if i < n and (Str.charAtOrReplacement(t, i) == '+' or Str.charAtOrReplacement(t, i) == '-') {
    i = i + 1
  }
  val rest = t.substring(i, n - i)
  if rest == "NaN" or rest == "Infinity" {
    return true
  }
  var digits = 0
  while i < n and isAsciiDigit(Str.charAtOrReplacement(t, i)) {
    i = i + 1
    digits = digits + 1
  }
  if i < n and Str.charAtOrReplacement(t, i) == '.' {
    i = i + 1
    while i < n and isAsciiDigit(Str.charAtOrReplacement(t, i)) {
      i = i + 1
      digits = digits + 1
    }
  }
  if digits == 0 {
    return false
  }
  if i < n and (Str.charAtOrReplacement(t, i) == 'e' or Str.charAtOrReplacement(t, i) == 'E') {
    i = i + 1
    if i < n and (Str.charAtOrReplacement(t, i) == '+' or Str.charAtOrReplacement(t, i) == '-') {
      i = i + 1
    }
    var expDigits = 0
    while i < n and isAsciiDigit(Str.charAtOrReplacement(t, i)) {
      i = i + 1
      expDigits = expDigits + 1
    }
    if expDigits == 0 {
      return false
    }
  }
  i == n
}

func isAsciiDigit(c: in Char): Bool {
  c >= '0' and c <= '9'
}

/// Trims and matches "true"/"false" case-insensitively - the documented
/// `System.Boolean.TryParse` behaviour.
pub func hostTryParseBool(s: in String, value: out Bool): Bool {
  value = false
  val t = Str.toLower(Str.trim(s))
  if t == "true" {
    value = true
    true
  } else if t == "false" {
    true
  } else {
    false
  }
}
