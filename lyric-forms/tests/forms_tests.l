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
  match Parse.requiredText(Forms.fieldPath("name"), "  Acme  ") {
    case Ok(v) -> assertEqual(v, "Acme", "trimmed value")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  match Parse.requiredText(Forms.fieldPath("name"), "   ") {
    case Ok(_) -> assertTrue(false, "expected Required")
    case Err(e) -> assertEqual(Forms.messageOf(e, "Name"), "Name is required", "message")
  }
}

test "longInRange distinguishes required, invalid and out-of-range" {
  assertEqual(
    Forms.messageOf(err1(Parse.longInRange(Forms.fieldPath("limit"), "", 0, 100)), "Limit"),
    "Limit is required",
    "empty"
  )
  assertEqual(
    Forms.messageOf(err1(Parse.longInRange(Forms.fieldPath("limit"), "12a", 0, 100)), "Limit"),
    "Limit must be a whole number",
    "non-numeric"
  )
  assertEqual(
    Forms.messageOf(err1(Parse.longInRange(Forms.fieldPath("limit"), "101", 0, 100)), "Limit"),
    "Limit must be between 0 and 100",
    "too large"
  )
  match Parse.longInRange(Forms.fieldPath("limit"), " 42 ", 0, 100) {
    case Ok(v) -> assertTrue(v == 42, "parsed 42")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
}

test "optionalLongInRange treats blank as None" {
  match Parse.optionalLongInRange(Forms.fieldPath("limit"), "  ", 0, 100) {
    case Ok(None) -> assertTrue(true, "blank is None")
    case _ -> assertTrue(false, "expected Ok(None)")
  }
}

test "email accepts a plausible address and rejects malformed ones" {
  match Parse.email(Forms.fieldPath("email"), "a@example.com") {
    case Ok(v) -> assertEqual(v, "a@example.com", "accepted")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
  for bad in ["@example.com", "a@", "a@b@c.com", "a@localhost", "plain"] {
    match Parse.email(Forms.fieldPath("email"), bad) {
      case Ok(_) -> assertTrue(false, "should reject " + bad)
      case Err(_) -> assertTrue(true, "rejected")
    }
  }
}

test "collect gathers every error and returns fallbacks" {
  val errs: List[Forms.FieldError] = newList()
  val name = Parse.collect(errs, Parse.requiredText(Forms.fieldPath("name"), ""), "?")
  val limit = Parse.collect(errs, Parse.longInRange(Forms.fieldPath("limit"), "x", 0, 10), -1)
  assertEqual(name, "?", "fallback string")
  assertTrue(limit == -1, "fallback long")
  assertEqualInt(errs.count, 2, "two errors")
  assertTrue(Forms.hasErrorFor(errs, Forms.fieldPath("name")), "name error")
  assertTrue(Forms.hasErrorFor(errs, Forms.fieldPath("limit")), "limit error")
  assertFalse(Forms.hasErrorFor(errs, Forms.fieldPath("email")), "no email error")
}

test "formErrors returns only cross-field errors" {
  val errs: List[Forms.FieldError] = newList()
  errs.add(Forms.Required(field = Forms.fieldPath("name")))
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

test "field paths compare by segment and render readably" {
  val lines = Forms.fieldPath("lines")
  val qty3 = Forms.child(Forms.item(lines, 3), "qty")
  assertEqual(Forms.pathText(qty3), "lines[#3].qty", "text")
  assertTrue(Forms.samePath(qty3, Forms.child(Forms.item(Forms.fieldPath("lines"), 3), "qty")), "same")
  assertFalse(Forms.samePath(qty3, Forms.child(Forms.item(lines, 4), "qty")), "other row")
  assertFalse(Forms.samePath(lines, Forms.fieldPath("line")), "other name")
  assertTrue(Forms.isWithin(qty3, Forms.item(lines, 3)), "within row")
  assertTrue(Forms.isWithin(qty3, lines), "within list")
  assertFalse(Forms.isWithin(lines, qty3), "not the other way")
}

test "errorsWithin selects one row's errors" {
  val lines = Forms.fieldPath("lines")
  val errs: List[Forms.FieldError] = newList()
  errs.add(Forms.Required(field = Forms.child(Forms.item(lines, 1), "sku")))
  errs.add(Forms.Required(field = Forms.child(Forms.item(lines, 2), "sku")))
  errs.add(Forms.Required(field = Forms.child(Forms.item(lines, 2), "qty")))
  assertEqualInt(Forms.errorsWithin(errs, Forms.item(lines, 2)).count, 2, "row 2")
  assertEqualInt(Forms.errorsWithin(errs, lines).count, 3, "all rows")
  assertEqualInt(Forms.errorsFor(errs, Forms.item(lines, 2)).count, 0, "exact match only")
}

func rowIds(rs: in Forms.DraftRows[String]): String {
  var s = ""
  for r in rs.rows {
    s = s + r.id.toString() + "=" + r.draft + " "
  }
  return s
}

test "draft rows keep their ids through add, remove, move and update" {
  val empty: Forms.DraftRows[String] = Forms.emptyRows()
  val a = Forms.addRow(empty, "a")
  val ab = Forms.addRow(a, "b")
  val abc = Forms.addRow(ab, "c")
  assertEqual(rowIds(abc), "1=a 2=b 3=c ", "added")
  val ac = Forms.removeRow(abc, 2)
  assertEqual(rowIds(ac), "1=a 3=c ", "removed")
  val acd = Forms.addRow(ac, "d")
  assertEqual(rowIds(acd), "1=a 3=c 4=d ", "ids are not reused")
  assertEqual(rowIds(Forms.moveRow(acd, 4, 0)), "4=d 1=a 3=c ", "moved to front")
  assertEqual(rowIds(Forms.moveRow(acd, 1, 99)), "3=c 4=d 1=a ", "moved past end")
  assertEqual(rowIds(Forms.moveRow(acd, 9, 0)), "1=a 3=c 4=d ", "unknown row unchanged")
  val up = Forms.updateRow(acd, 3, { s: String -> s + "!" })
  assertEqual(rowIds(up), "1=a 3=c! 4=d ", "updated")
  assertEqual(rowIds(abc), "1=a 2=b 3=c ", "original untouched")
  val drafts: List[String] = newList()
  drafts.add("x")
  drafts.add("y")
  val xy = Forms.rowsOf(drafts)
  assertEqual(rowIds(Forms.addRow(xy, "z")), "1=x 2=y 3=z ", "rowsOf then add")
}

func positive(path: in Forms.FieldPath, d: in String): Result[Long, List[Forms.FieldError]] {
  val errs: List[Forms.FieldError] = newList()
  val v = Parse.collect(errs, Parse.longInRange(Forms.child(path, "qty"), d, 1, 99), 0)
  if errs.count > 0 {
    return Err(error = errs)
  }
  return Ok(value = v)
}

test "validateRows reports every row's errors at its row path" {
  val empty: Forms.DraftRows[String] = Forms.emptyRows()
  val rs = Forms.addRow(Forms.addRow(Forms.addRow(empty, "5"), "x"), "0")
  val lines = Forms.fieldPath("lines")
  match Forms.validateRows(rs, lines, positive) {
    case Ok(_) -> assertTrue(false, "expected errors")
    case Err(errs) -> {
      assertEqualInt(errs.count, 2, "two bad rows")
      assertTrue(Forms.hasErrorFor(errs, Forms.child(Forms.item(lines, 2), "qty")), "row 2")
      assertTrue(Forms.hasErrorFor(errs, Forms.child(Forms.item(lines, 3), "qty")), "row 3")
    }
  }
  val good = Forms.addRow(Forms.addRow(empty, "5"), "7")
  match Forms.validateRows(good, lines, positive) {
    case Ok(vs) -> assertTrue(vs.count == 2 and vs[0] == 5 and vs[1] == 7, "values in order")
    case Err(_) -> assertTrue(false, "expected Ok")
  }
}
