// std/parse.l - Safe parsing for primitive types.
//
// All `tryParse*` functions return Result[T, ParseError] to enforce
// explicit error handling. The `parse*` convenience functions panic on
// failure and should be reserved for trusted literals or startup code.
package Std.Parse

import Std.Errors { ParseError }

// ---------------------------------------------------------------------------
// Int parsing.
// ---------------------------------------------------------------------------

@axiom
extern package System.Int32 {
  func tryParseInt(s: in String, out: in String): Bool
}

// Parse a string as an Int. Returns Err on invalid format or overflow.
pub func tryParseInt(s: in String): Result[Int, ParseError] {
  // Future implementation: delegate to the curated numeric parse
  // boundary and distinguish invalid format from range overflow.
  if s.length == 0 {
    Err(error = InvalidFormat(input = s, expected = "non-empty integer"))
  } else {
    // Placeholder until the host parse boundary is wired.
    if (s[0] >= '0' and s[0] <= '9') or (s[0] == '-' and s.length > 1) {
      Ok(value = 0)  // Placeholder result; host parser supplies the real value.
    } else {
      Err(error = InvalidFormat(input = s, expected = "integer"))
    }
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
  // Placeholder until the host parse boundary is wired.
  if s.length == 0 {
    Err(error = InvalidFormat(input = s, expected = "non-empty long"))
  } else {
    if (s[0] >= '0' and s[0] <= '9') or (s[0] == '-' and s.length > 1) {
      Ok(value = 0)  // Placeholder result; host parser supplies the real value.
    } else {
      Err(error = InvalidFormat(input = s, expected = "long"))
    }
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
  // Placeholder until the host parse boundary is wired.
  if s.length == 0 {
    Err(error = InvalidFormat(input = s, expected = "non-empty float"))
  } else {
    Ok(value = 0.0)  // Placeholder result; host parser supplies the real value.
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
