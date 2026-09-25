//! tests/forms_tests.l — unit tests for Forms and Forms.Parse.
@test_module
package Forms.FormsTests

import Std.Core
import Std.Testing
import Forms
import Forms.Parse

func err1(r: in Result[Long, Forms.FieldError]): Forms.FieldError {
  return match r { case Ok(_) -> panic("expected Err"); case Err(e) -> e }
}

test "requiredText trims and rejects blank input" {
  match Parse.requiredText("name", "  Acme  ") {
    case Ok(v) -> assertEqual(v, "Acme", "trimmed value")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  match Parse.requiredText("name", "   ") {
    case Ok(_) -> assertTrue(false, "expected Required")
    case Err(e) -> assertEqual(Forms.messageOf(e, "Name"), "Name is required", "message")
  }
}

test "longInRange distinguishes required, invalid and out-of-range" {
  assertEqual(Forms.messageOf(err1(Parse.longInRange("limit", "", 0, 100)), "Limit"), "Limit is required", "empty")
  assertEqual(
    Forms.messageOf(err1(Parse.longInRange("limit", "12a", 0, 100)), "Limit"),
    "Limit must be a whole number",
    "non-numeric"
  )
  assertEqual(
    Forms.messageOf(err1(Parse.longInRange("limit", "101", 0, 100)), "Limit"),
    "Limit must be between 0 and 100",
    "too large"
  )
  match Parse.longInRange("limit", " 42 ", 0, 100) {
    case Ok(v) -> assertTrue(v == 42, "parsed 42")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
}

test "optionalLongInRange treats blank as None" {
  match Parse.optionalLongInRange("limit", "  ", 0, 100) {
    case Ok(None) -> assertTrue(true, "blank is None")
    case _ -> assertTrue(false, "expected Ok(None)")
  }
}

test "email accepts a plausible address and rejects malformed ones" {
  match Parse.email("email", "a@example.com") {
    case Ok(v) -> assertEqual(v, "a@example.com", "accepted")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  for bad in ["@example.com", "a@", "a@b@c.com", "a@localhost", "plain"] {
    match Parse.email("email", bad) {
      case Ok(_) -> assertTrue(false, "should reject " + bad)
      case Err(_) -> assertTrue(true, "rejected")
    }
  }
}

test "collect gathers every error and returns fallbacks" {
  val errs: List[Forms.FieldError] = newList()
  val name = Parse.collect(errs, Parse.requiredText("name", ""), "?")
  val limit = Parse.collect(errs, Parse.longInRange("limit", "x", 0, 10), -1)
  assertEqual(name, "?", "fallback string")
  assertTrue(limit == -1, "fallback long")
  assertEqualInt(errs.count, 2, "two errors")
  assertTrue(Forms.hasErrorFor(errs, "name"), "name error")
  assertTrue(Forms.hasErrorFor(errs, "limit"), "limit error")
  assertFalse(Forms.hasErrorFor(errs, "email"), "no email error")
}

test "formErrors returns only cross-field errors" {
  val errs: List[Forms.FieldError] = newList()
  errs.add(Forms.Required(field = "name"))
  errs.add(Forms.CrossField(message = "End date must follow start date"))
  val fe = Forms.formErrors(errs)
  assertEqualInt(fe.count, 1, "one form error")
  assertEqual(Forms.messageOf(fe[0], "ignored"), "End date must follow start date", "message")
}

test "schema builders and lookup" {
  val fields: List[Forms.FieldSpec] = newList()
  fields.add(Forms.required(Forms.fieldSpec("name", "Name", Forms.InputKind.Text)))
  fields.add(Forms.bounded(Forms.fieldSpec("limit", "Credit limit", Forms.InputKind.Number), 0, 1000))
  val s = Forms.schema(fields)
  assertEqual(Forms.labelOf(s, "limit"), "Credit limit", "label")
  assertEqual(Forms.labelOf(s, "missing"), "missing", "fallback label")
  match Forms.specOf(s, "limit") {
    case Some(f) -> match f.bounds {
      case Some(b) -> assertTrue(b.min == 0 and b.max == 1000, "bounds")
      case None -> assertTrue(false, "expected bounds")
    }
    case None -> assertTrue(false, "expected spec")
  }
  match Forms.specOf(s, "name") {
    case Some(f) -> assertTrue(f.required, "required")
    case None -> assertTrue(false, "expected spec")
  }
}
