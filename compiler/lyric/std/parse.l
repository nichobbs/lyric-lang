// std/parse.l - Safe parsing for primitive types.
//
// All `tryParse*` functions return Result[T, ParseError] to enforce
// explicit error handling. The `parse*` convenience functions panic on
// failure and should be reserved for trusted literals or startup code.
//
// Numeric parsing routes through host builtins (`hostParseIntIsValid`,
// `hostParseIntValue`, …) that the emitter resolves to static methods
// on `Lyric.Stdlib.Parse`.  Until Lyric grows real out-parameters the
// host pair is `IsValid` (returns Bool) + `Value` (returns 0 on
// invalid) — callers gate `Value` behind `IsValid`.
package Std.Parse

import Std.Errors { ParseError }

// ---------------------------------------------------------------------------
// Int parsing.
// ---------------------------------------------------------------------------

// Parse a string as an Int. Returns Err on invalid format or overflow.
pub func tryParseInt(s: in String): Result[Int, ParseError] {
  if hostParseIntIsValid(s) {
    Ok(value = hostParseIntValue(s))
  } else {
    Err(error = InvalidFormat(input = s, expected = "integer"))
  }
}

// Parse a string as an Int, panic on failure.
pub func parseInt(s: in String): Int {
  match tryParseInt(s) {
    case Ok(value) -> value
    case Err(e) -> panic(ParseError.message(e))
  }
}

// ---------------------------------------------------------------------------
// Long parsing.
// ---------------------------------------------------------------------------

pub func tryParseLong(s: in String): Result[Long, ParseError] {
  if hostParseLongIsValid(s) {
    Ok(value = hostParseLongValue(s))
  } else {
    Err(error = InvalidFormat(input = s, expected = "long"))
  }
}

pub func parseLong(s: in String): Long {
  match tryParseLong(s) {
    case Ok(value) -> value
    case Err(e) -> panic(ParseError.message(e))
  }
}

// ---------------------------------------------------------------------------
// Double parsing.
// ---------------------------------------------------------------------------

pub func tryParseDouble(s: in String): Result[Double, ParseError] {
  if hostParseDoubleIsValid(s) {
    Ok(value = hostParseDoubleValue(s))
  } else {
    Err(error = InvalidFormat(input = s, expected = "double"))
  }
}

pub func parseDouble(s: in String): Double {
  match tryParseDouble(s) {
    case Ok(value) -> value
    case Err(e) -> panic(ParseError.message(e))
  }
}

// ---------------------------------------------------------------------------
// Bool parsing.
// ---------------------------------------------------------------------------

pub func tryParseBool(s: in String): Result[Bool, ParseError] {
  val lower = s.trim().toLower()
  if lower == "true" {
    Ok(value = true)
  } else if lower == "false" {
    Ok(value = false)
  } else {
    Err(error = InvalidFormat(input = s, expected = "true or false"))
  }
}

pub func parseBool(s: in String): Bool {
  match tryParseBool(s) {
    case Ok(value) -> value
    case Err(e) -> panic(ParseError.message(e))
  }
}
