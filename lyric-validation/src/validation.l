/// Validation — declarative input validation for Lyric.
///
/// Provides composable validator combinators that return `[ValidationError]` —
/// an empty list means the value is valid.  This library is distinct from
/// contract `requires:` clauses: `requires:` enforces internal function
/// invariants (programmer errors), while Validation checks external user-
/// supplied inputs (user-facing error messages).
///
/// Usage:
///
///   import Validation
///   import Std.Core
///
///   func validateUser(name: in String, age: in Int, email: in String): [ValidationError] {
///     return Validation.all([
///       Validation.required(name, "name"),
///       Validation.minLength(name, "name", 2),
///       Validation.maxLength(name, "name", 100),
///       Validation.rangeValue(age, "age", 0, 150),
///       Validation.email(email, "email"),
///     ])
///   }
///
///   val errs = validateUser("", -1, "not-an-email")
///   if Validation.isValid(errs) {
///     // proceed
///   } else {
///     // report errs to the caller
///   }
///
///   // Or lift to Result:
///   val result = Validation.toResult(user, validateUser(user.name, user.age, user.email))
///
/// See docs/03-decision-log.md D056 and lyric-validation/README.md.

@runtime_checked
package Validation

import Std.Core
import Std.Collections
import Std.Regex

// ─── Error type ───────────────────────────────────────────────────────────────

/// A single validation failure.
///
/// `field`   — the field or parameter name that failed (e.g. "username").
/// `message` — a human-readable description of the failure.
/// `code`    — a machine-readable code (e.g. "required", "minLength", "pattern").
@stable(since="0.1")
pub record ValidationError {
  field:   String
  message: String
  code:    String
}

// ─── Validator interface ───────────────────────────────────────────────────────

/// Generic validator interface.  Implement this to package a reusable
/// validation rule for a type `T`.  The built-in combinators do not require
/// this interface; use it when you want to pass validators as values.
@stable(since="0.1")
pub interface Validator[T] {
  /// Validate `value` for the named `field`.  Returns an empty list when valid.
  func validate(value: in T, field: in String): [ValidationError]
}

// ─── String validators ────────────────────────────────────────────────────────

/// Fail when `value` is an empty string.
@stable(since="0.1")
pub func required(value: in String, field: in String): [ValidationError] {
  if value.length == 0 {
    return err(field, "required", field + " is required")
  }
  return []
}

/// Fail when `value` is shorter than `min` characters.
@stable(since="0.1")
pub func minLength(value: in String, field: in String, min: in Int): [ValidationError]
  requires: min >= 0
{
  if value.length < min {
    return err(field, "minLength",
      field + " must be at least " + min.toString() + " character(s)")
  }
  return []
}

/// Fail when `value` is longer than `max` characters.
@stable(since="0.1")
pub func maxLength(value: in String, field: in String, max: in Int): [ValidationError]
  requires: max >= 0
{
  if value.length > max {
    return err(field, "maxLength",
      field + " must be at most " + max.toString() + " character(s)")
  }
  return []
}

/// Fail when `value` does not have exactly `length` characters.
@stable(since="0.1")
pub func exactLength(value: in String, field: in String, length: in Int): [ValidationError]
  requires: length >= 0
{
  if value.length != length {
    return err(field, "exactLength",
      field + " must be exactly " + length.toString() + " character(s)")
  }
  return []
}

/// Fail when `value` is empty or contains only whitespace characters.
///
/// Whitespace is defined as space (0x20), tab (0x09), carriage return (0x0D),
/// and newline (0x0A).
@stable(since="0.1")
pub func notBlank(value: in String, field: in String): [ValidationError] {
  if value.length == 0 {
    return err(field, "notBlank", field + " must not be blank")
  }
  var i = 0
  while i < value.length {
    val ch = value.charAt(i).toString()
    if ch != " " and ch != "\t" and ch != "\r" and ch != "\n" {
      return []
    }
    i = i + 1
  }
  return err(field, "notBlank", field + " must not be blank")
}

/// Fail when `value` does not match the regular expression `pattern`.
///
/// `patternDesc` is the human-readable description used in the error message
/// (e.g. "E.164 phone number").  When `pattern` is empty, all values pass.
@stable(since="0.1")
pub func matches(
  value:       in String,
  field:       in String,
  pattern:     in String,
  patternDesc: in String
): [ValidationError] {
  if pattern.length == 0 {
    return []
  }
  val r = Std.Regex.compile(pattern)
  if not Std.Regex.isMatch(r, value) {
    return err(field, "pattern", field + " must match " + patternDesc)
  }
  return []
}

/// Fail when `value` is not present in the `allowed` list.
///
/// Comparison is case-sensitive.  The allowed list is scanned linearly.
@stable(since="0.1")
pub func oneOf(value: in String, field: in String, allowed: in [String]): [ValidationError] {
  for option in allowed {
    if value == option { return [] }
  }
  var joined = ""
  var first  = true
  for option in allowed {
    if not first { joined = joined + ", " }
    joined = joined + option
    first  = false
  }
  return err(field, "oneOf", field + " must be one of: " + joined)
}

/// Email address validation.  Rejects obviously invalid addresses while
/// accepting well-formed ones.  Not a full RFC 5322 validator; pair with
/// a confirmation step for high-stakes flows.
///
/// Checks: non-empty; exactly one "@"; non-empty local part; non-empty
/// domain with at least one "."; no leading/trailing dots in local or
/// domain; no consecutive dots; no leading/trailing whitespace;
/// TLD of at least two characters; no CRLF/NUL (injection guard).
@stable(since="0.1")
pub func email(value: in String, field: in String): [ValidationError] {
  val badEmail = err(field, "email", field + " must be a valid email address")
  if value.length == 0 { return badEmail }
  // Reject CRLF/NUL — header injection guard.
  var k = 0
  while k < value.length {
    val ch = value.charAt(k).toString()
    if ch == "\r" or ch == "\n" or ch == "\u{0}" { return badEmail }
    k = k + 1
  }
  // Reject leading/trailing whitespace.
  val first = value.charAt(0).toString()
  val last  = value.charAt(value.length - 1).toString()
  if first == " " or first == "\t" or last == " " or last == "\t" { return badEmail }
  // Find the "@" — must appear exactly once.
  var atCount = 0
  var atIndex = -1
  var i = 0
  while i < value.length {
    if value.charAt(i).toString() == "@" {
      atCount = atCount + 1
      atIndex = i
    }
    i = i + 1
  }
  if atCount != 1 { return badEmail }
  // Local part: must be non-empty, must not start or end with ".", and
  // must not contain consecutive dots.
  if atIndex == 0 { return badEmail }
  val localFirst = value.charAt(0).toString()
  val localLast  = value.charAt(atIndex - 1).toString()
  if localFirst == "." or localLast == "." { return badEmail }
  var localPrevDot = false
  var li = 0
  while li < atIndex {
    val ch = value.charAt(li).toString()
    if ch == "." {
      if localPrevDot { return badEmail }
      localPrevDot = true
    } else {
      localPrevDot = false
    }
    li = li + 1
  }
  // Domain: must be non-empty, must not start or end with ".".
  val domainStart = atIndex + 1
  if domainStart >= value.length { return badEmail }
  val domainFirstCh = value.charAt(domainStart).toString()
  val domainLastCh  = value.charAt(value.length - 1).toString()
  if domainFirstCh == "." or domainLastCh == "." { return badEmail }
  // Domain: must contain at least one "." and no consecutive dots.
  var dotCount = 0
  var prevWasDot = false
  var j = domainStart
  while j < value.length {
    val ch = value.charAt(j).toString()
    if ch == "." {
      dotCount = dotCount + 1
      if prevWasDot { return badEmail }
      prevWasDot = true
    } else {
      prevWasDot = false
    }
    j = j + 1
  }
  if dotCount == 0 { return badEmail }
  // TLD: must be at least 2 characters.
  val lastDot = value.lastIndexOf(".")
  if lastDot < 0 { return badEmail }
  val tldLen = value.length - lastDot - 1
  if tldLen < 2 { return badEmail }
  return []
}

/// Fail when `value` does not start with "http://" or "https://".
@stable(since="0.1")
pub func url(value: in String, field: in String): [ValidationError] {
  if value.length == 0 {
    return err(field, "url", field + " must be a valid URL (http:// or https://)")
  }
  val startsHttp  = value.length >= 7 and value.substring(0, 7)  == "http://"
  val startsHttps = value.length >= 8 and value.substring(0, 8)  == "https://"
  if not startsHttp and not startsHttps {
    return err(field, "url", field + " must be a valid URL (http:// or https://)")
  }
  return []
}

// ─── Numeric validators ───────────────────────────────────────────────────────

/// Fail when `value` is less than `min`.
@stable(since="0.1")
pub func minValue(value: in Int, field: in String, min: in Int): [ValidationError] {
  if value < min {
    return err(field, "minValue",
      field + " must be at least " + min.toString())
  }
  return []
}

/// Fail when `value` is greater than `max`.
@stable(since="0.1")
pub func maxValue(value: in Int, field: in String, max: in Int): [ValidationError] {
  if value > max {
    return err(field, "maxValue",
      field + " must be at most " + max.toString())
  }
  return []
}

/// Fail when `value` is outside the closed range [`min`, `max`].
@stable(since="0.1")
pub func rangeValue(value: in Int, field: in String, min: in Int, max: in Int): [ValidationError]
  requires: min <= max
{
  if value < min or value > max {
    return err(field, "rangeValue",
      field + " must be between " + min.toString() + " and " + max.toString() + " (inclusive)")
  }
  return []
}

// ─── Generic combinators ──────────────────────────────────────────────────────

/// Concatenate two error lists.  The result is valid iff both inputs are empty.
@stable(since="0.1")
pub func combine(a: in [ValidationError], b: in [ValidationError]): [ValidationError] {
  return a + b
}

/// Concatenate all error lists in `errors`.  The result is valid iff every
/// input list is empty.  Typically used with a list literal:
///
///   Validation.all([
///     Validation.required(name, "name"),
///     Validation.minLength(name, "name", 2),
///   ])
@stable(since="0.1")
pub func all(errors: in [[ValidationError]]): [ValidationError] {
  var result: [ValidationError] = []
  for errs in errors {
    result = result + errs
  }
  return result
}

/// Return true iff the error list is empty (all validations passed).
@stable(since="0.1")
pub func isValid(errors: in [ValidationError]): Bool {
  return errors.length == 0
}

/// Return the first validation error, or `None` if the list is empty.
@stable(since="0.1")
pub func firstError(errors: in [ValidationError]): Option[ValidationError] {
  for e in errors {
    return Some(value = e)
  }
  return None
}

/// Lift a validated value into a `Result`.
/// Returns `Ok(value)` when `errors` is empty; `Err(errors)` otherwise.
@stable(since="0.1")
pub func toResult[T](value: in T, errors: in [ValidationError]): Result[T, [ValidationError]] {
  if errors.length == 0 {
    return Ok(value)
  }
  return Err(errors)
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Construct a single-element error list.
func err(field: in String, code: in String, message: in String): [ValidationError] {
  return [ValidationError(field = field, message = message, code = code)]
}
