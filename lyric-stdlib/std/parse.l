//! std/parse.l - Safe parsing for primitive types.
//!
//! Two families of converters:
//!
//!   tryParseXxx(s) : Result[T, ParseError]
//!     The original error-rich shape — keeps the input + reason for
//!     callers that want to surface a useful diagnostic.
//!
//!   parseOptXxx(s) : Option[T]
//!     Pure-Lyric for Int and Long (decimal, sign-aware, overflow-checked,
//!     leading-whitespace tolerant).  Double and Bool continue to route
//!     through the BCL host for locale-correct and IEEE-754-accurate parsing.
//!
//!   parseXxx(s) : T   (panicking)
//!     Reserved for trusted literals or startup code; calls
//!     `tryParseXxx` and panics with the `ParseError`'s message on
//!     failure.
package Std.Parse

import Std.Core
import Std.Errors
// Import CharHost directly rather than Std.Char to avoid transitively
// re-exporting Std.Char's toLower/toUpper into modules that import Std.Parse.
import Std.CharHost as ParseCharHost
import Std.ParseHost as Host

// =====================================================================
// ASCII whitespace check (inline, avoids an extra import).
// =====================================================================
// True for the six ASCII whitespace characters BCL TryParse skips.
func isParseWhiteSpace(c: in Char): Bool {
  val cp = ParseCharHost.hostCharToInt(c)
  cp == 32 or cp == 9 or cp == 10 or cp == 11 or cp == 12 or cp == 13
}

// =====================================================================
// Pure-Lyric decimal integer parsers.
//
// Algorithm: accumulate digits as a negative number to cover the full
// symmetric range (Int32.MinValue = -2147483648 can't be represented
// as a positive Int32).  Overflow is detected before each multiplication
// and at the sign-flip for positive results.
//
// Accepts the same input shape as BCL TryParse:
//   [ whitespace ] [ sign ] digits [ whitespace ]
// where sign is '+' or '-' and digits are ASCII '0'-'9'.
// =====================================================================
@stable(since = "1.0")
pub func parseOptInt(s: in String): Option[Int] {
  val len = s.length
  if len == 0 {
    return None
  }
  var i = 0
  while i < len and isParseWhiteSpace(s[i]) {
    i += 1
  }
  if i == len {
    return None
  }
  var negative = false
  if s[i] == '-' {
    negative = true
    i += 1
  } else if s[i] == '+' {
    i += 1
  }
  if i == len {
    return None
  }
  // Accumulate as negative to handle the full Int32 range.
  var acc = 0
  var hasDigits = false
  while i < len {
    val cp = ParseCharHost.hostCharToInt(s[i])
    if cp < 48 or cp > 57 {
      // Non-digit: must be trailing whitespace only, then end of string.
      while i < len and isParseWhiteSpace(s[i]) {
        i += 1
      }
      if i != len {
        return None
      }
    } else {
      val d = cp - 48  // '0' = 48
      hasDigits = true
      // Overflow guard: acc * 10 - d must stay >= -2147483648.
      // Threshold: -214748364 * 10 - 8 = -2147483648 (the minimum).
      if acc < -214748364 {
        return None
      }
      if acc == -214748364 and d > 8 {
        return None
      }
      acc = acc * 10 - d
      i += 1
    }
  }
  if not hasDigits {
    return None
  }
  if negative {
    Some(value = acc)
  } else {
    // For positive results, -acc must fit in Int32 (max 2147483647).
    if acc == -2147483648 {
      return None
    }
    Some(value = -acc)
  }
}

@stable(since = "1.0")
pub func parseOptLong(s: in String): Option[Long] {
  val len = s.length
  if len == 0 {
    return None
  }
  var i = 0
  while i < len and isParseWhiteSpace(s[i]) {
    i += 1
  }
  if i == len {
    return None
  }
  var negative = false
  if s[i] == '-' {
    negative = true
    i += 1
  } else if s[i] == '+' {
    i += 1
  }
  if i == len {
    return None
  }
  // Accumulate as negative Long.
  // Threshold: -922337203685477580 * 10 - 8 = -9223372036854775808 (Int64.MinValue).
  var acc = 0i64
  var hasDigits = false
  while i < len {
    val cp = ParseCharHost.hostCharToInt(s[i])
    if cp < 48 or cp > 57 {
      while i < len and isParseWhiteSpace(s[i]) {
        i += 1
      }
      if i != len {
        return None
      }
    } else {
      val d = cp - 48
      hasDigits = true
      if acc < -922337203685477580i64 {
        return None
      }
      if acc == -922337203685477580i64 and d > 8 {
        return None
      }
      acc = acc * 10i64 - d.toLong()
      i += 1
    }
  }
  if not hasDigits {
    return None
  }
  if negative {
    Some(value = acc)
  } else {
    if acc == -9223372036854775808i64 {
      return None
    }
    Some(value = -acc)
  }
}

@stable(since = "1.0")
pub func parseOptDouble(s: in String): Option[Double] {
  var v: Double = default()
  if Host.hostTryParseDouble(s, v) {
    Some(value = v)
  } else {
    None
  }
}

@stable(since = "1.0")
pub func parseOptBool(s: in String): Option[Bool] {
  var v: Bool = default()
  if Host.hostTryParseBool(s, v) {
    Some(value = v)
  } else {
    None
  }
}

// =====================================================================
// Result-returning parsers — keep `ParseError` context for callers
// that want to surface a user-facing diagnostic.  Compose `parseOpt*`
// with a `Some` / `None` → `Ok` / `Err` lift.
// =====================================================================
@stable(since = "1.0")
pub func tryParseInt(s: in String): Result[Int, ParseError] {
  match parseOptInt(s) {
    case Some(v) -> Ok(value = v)
    case None -> Err(error = InvalidFormat(input = s, expected = "integer"))
  }
}

@stable(since = "1.0")
pub func tryParseLong(s: in String): Result[Long, ParseError] {
  match parseOptLong(s) {
    case Some(v) -> Ok(value = v)
    case None -> Err(error = InvalidFormat(input = s, expected = "long"))
  }
}

@stable(since = "1.0")
pub func tryParseDouble(s: in String): Result[Double, ParseError] {
  match parseOptDouble(s) {
    case Some(v) -> Ok(value = v)
    case None -> Err(error = InvalidFormat(input = s, expected = "double"))
  }
}

@stable(since = "1.0")
pub func tryParseBool(s: in String): Result[Bool, ParseError] {
  match parseOptBool(s) {
    case Some(v) -> Ok(value = v)
    case None -> Err(error = InvalidFormat(input = s, expected = "true or false"))
  }
}

// =====================================================================
// Panicking convenience family.
// =====================================================================
@stable(since = "1.0")
pub func parseInt(s: in String): Int {
  match tryParseInt(s) {
    case Ok(v) -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}

@stable(since = "1.0")
pub func parseLong(s: in String): Long {
  match tryParseLong(s) {
    case Ok(v) -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}

@stable(since = "1.0")
pub func parseDouble(s: in String): Double {
  match tryParseDouble(s) {
    case Ok(v) -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}

@stable(since = "1.0")
pub func parseBool(s: in String): Bool {
  match tryParseBool(s) {
    case Ok(v) -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}
