// std/parse.l - Safe parsing for primitive types.
//
// Two families of converters:
//
//   tryParseXxx(s) : Result[T, ParseError]
//     The original error-rich shape — keeps the input + reason for
//     callers that want to surface a useful diagnostic.
//
//   parseOptXxx(s) : Option[T]
//     Newer, route through the BCL's `TryParse` family via FFI
//     out-params for a single-pass `Some(value)` / `None` shape.
//
//   parseXxx(s) : T   (panicking)
//     Reserved for trusted literals or startup code; calls
//     `tryParseXxx` and panics with the `ParseError`'s message on
//     failure.
package Std.Parse

import Std.Core
import Std.Errors

// =====================================================================
// FFI to the BCL TryParse family — single host call decides validity
// + value via an `out` parameter.  Used by the Lyric-side `parseOpt*`
// wrappers; not generally meant for direct use.
// =====================================================================

@externTarget("System.Int32.TryParse")
pub func hostTryParseInt(s: in String, value: out Int): Bool = ()

@externTarget("System.Int64.TryParse")
pub func hostTryParseLong(s: in String, value: out Long): Bool = ()

@externTarget("System.Double.TryParse")
pub func hostTryParseDouble(s: in String, value: out Double): Bool = ()

@externTarget("System.Boolean.TryParse")
pub func hostTryParseBool(s: in String, value: out Bool): Bool = ()

// =====================================================================
// Option-returning parsers — preferred for new code.
// =====================================================================

pub func parseOptInt(s: in String): Option[Int] {
  var v: Int = default()
  if hostTryParseInt(s, v) { Some(value = v) } else { None }
}

pub func parseOptLong(s: in String): Option[Long] {
  var v: Long = default()
  if hostTryParseLong(s, v) { Some(value = v) } else { None }
}

pub func parseOptDouble(s: in String): Option[Double] {
  var v: Double = default()
  if hostTryParseDouble(s, v) { Some(value = v) } else { None }
}

pub func parseOptBool(s: in String): Option[Bool] {
  var v: Bool = default()
  if hostTryParseBool(s, v) { Some(value = v) } else { None }
}

// =====================================================================
// Result-returning parsers — keep `ParseError` context for callers
// that want to surface a user-facing diagnostic.  Compose `parseOpt*`
// with a `Some` / `None` → `Ok` / `Err` lift.
// =====================================================================

pub func tryParseInt(s: in String): Result[Int, ParseError] {
  match parseOptInt(s) {
    case Some(v) -> Ok(value = v)
    case None    -> Err(error = InvalidFormat(input = s, expected = "integer"))
  }
}

pub func tryParseLong(s: in String): Result[Long, ParseError] {
  match parseOptLong(s) {
    case Some(v) -> Ok(value = v)
    case None    -> Err(error = InvalidFormat(input = s, expected = "long"))
  }
}

pub func tryParseDouble(s: in String): Result[Double, ParseError] {
  match parseOptDouble(s) {
    case Some(v) -> Ok(value = v)
    case None    -> Err(error = InvalidFormat(input = s, expected = "double"))
  }
}

pub func tryParseBool(s: in String): Result[Bool, ParseError] {
  match parseOptBool(s) {
    case Some(v) -> Ok(value = v)
    case None    -> Err(error = InvalidFormat(input = s, expected = "true or false"))
  }
}

// =====================================================================
// Panicking convenience family.
// =====================================================================

pub func parseInt(s: in String): Int {
  match tryParseInt(s) {
    case Ok(v)  -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}

pub func parseLong(s: in String): Long {
  match tryParseLong(s) {
    case Ok(v)  -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}

pub func parseDouble(s: in String): Double {
  match tryParseDouble(s) {
    case Ok(v)  -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}

pub func parseBool(s: in String): Bool {
  match tryParseBool(s) {
    case Ok(v)  -> v
    case Err(e) -> panic(ParseError.message(e))
  }
}
