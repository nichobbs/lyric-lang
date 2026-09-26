//! Forms.Parse — field parsers that turn draft text into typed values or a
//! `FieldError` (docs/65-ui-library-sketch.md §11).
//! Stability: @experimental — Phase U1 of docs/65.
//!
//! A validate function parses every field, collecting all errors rather than
//! stopping at the first, so the user sees every problem at once:
//!
//!   val errs: List[FieldError] = newList()
//!   val name = Parse.collect(errs, Parse.requiredText(fieldPath("name"), d.name), "")
//!   val limit = Parse.collect(errs, Parse.longInRange(fieldPath("creditLimit"), d.creditLimit, 0, 1000000), 0)
//!   if errs.count > 0 { return Err(error = errs) }
//!   return Ok(value = Customer(name = name, creditLimit = limit))
//!
//! `collect` appends to a list the caller created locally, so a validate
//! function built this way stays deterministic and free of side effects
//! visible to its caller.
@runtime_checked
package Forms.Parse

import Std.Core
import Std.String
import Std.Parse as P
import Forms.{FieldError, FieldPath, Required, Invalid, OutOfRange, TooLong}

/// The value of `r`, or `fallback` after appending the error to `errs`.
pub func collect[T](errs: in List[FieldError], r: in Result[T, FieldError], fallback: in T): T {
  return match r { case Ok(v) -> v; case Err(e) -> { errs.add(e); fallback } }
}

/// `raw` with surrounding whitespace removed; `Required` when that is empty.
pub func requiredText(field: in FieldPath, raw: in String): Result[String, FieldError] {
  val t = trim(raw)
  if t.length == 0 {
    return Err(error = Required(field = field))
  }
  return Ok(value = t)
}

/// `raw` trimmed, or `None` when that is empty.
pub func optionalText(raw: in String): Option[String] {
  val t = trim(raw)
  if t.length == 0 {
    return None
  }
  return Some(value = t)
}

/// `Ok(text)` when `text` has at most `max` characters, else `TooLong`.
pub func withinLength(field: in FieldPath, text: in String, max: in Int): Result[String, FieldError]
  requires: max > 0
{
  if text.length > max {
    return Err(error = TooLong(field = field, max = max))
  }
  return Ok(value = text)
}

/// `raw` parsed as a whole number in `min ..= max`.  Empty input is
/// `Required`; non-numeric input is `Invalid`; out-of-range is `OutOfRange`.
pub func longInRange(field: in FieldPath, raw: in String, min: in Long, max: in Long): Result[Long, FieldError]
  requires: min <= max
{
  val t = trim(raw)
  if t.length == 0 {
    return Err(error = Required(field = field))
  }
  return match P.parseOptLong(t) {
    case None -> Err(error = Invalid(field = field, reason = "must be a whole number"))
    case Some(v) -> if v < min or v > max {
      Err(error = OutOfRange(field = field, min = min, max = max))
    } else {
      Ok(value = v)
    }
  }
}

/// Like `longInRange`, but empty input is `Ok(None)`.
pub func optionalLongInRange(
  field: in FieldPath, raw: in String, min: in Long, max: in Long
): Result[Option[Long], FieldError]
  requires: min <= max
{
  if trim(raw).length == 0 {
    return Ok(value = None)
  }
  return match longInRange(field, raw, min, max) {
    case Ok(v) -> Ok(value = Some(value = v))
    case Err(e) -> Err(error = e)
  }
}

/// `raw` as one of `allowed` (compared after trimming).  Empty input is
/// `Required`; anything else outside `allowed` is `Invalid`.
pub func oneOf(field: in FieldPath, raw: in String, allowed: in List[String]): Result[String, FieldError] {
  val t = trim(raw)
  if t.length == 0 {
    return Err(error = Required(field = field))
  }
  for a in allowed {
    if a == t {
      return Ok(value = t)
    }
  }
  return Err(error = Invalid(field = field, reason = "is not one of the allowed values"))
}

/// A minimal structural email check: one `@` with text on both sides and a
/// `.` in the domain part.  Deliverability is out of scope; use an effect for
/// anything stronger.
pub func email(field: in FieldPath, raw: in String): Result[String, FieldError] {
  return match requiredText(field, raw) {
    case Err(e) -> Err(error = e)
    case Ok(t) -> match indexOf(t, "@") {
      case None -> Err(error = Invalid(field = field, reason = "must be an email address"))
      case Some(at) -> {
        val domain = substring(t, at + 1)
        if at == 0 or domain.length == 0 or contains(domain, "@") or not contains(domain, ".") {
          Err(error = Invalid(field = field, reason = "must be an email address"))
        } else {
          Ok(value = t)
        }
      }
    }
  }
}
