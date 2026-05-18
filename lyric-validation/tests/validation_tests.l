// tests/validation_tests.l — test suite for the Validation package.
// Tests both positive cases (valid input → empty list) and negative cases
// (invalid input → non-empty error list with the expected code).

@test_module
package Validation.ValidationTests

import Std.Core
import Std.Testing
import Validation

// ─── required ────────────────────────────────────────────────────────────────

test "required: empty string returns one error with code 'required'" {
  val errs = Validation.required("", "username")
  assertTrue(errs.length == 1, "expected one error for empty string")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> {
      assertEqual(e.code,  "required", "code")
      assertEqual(e.field, "username", "field")
    }
  }
}

test "required: non-empty string returns no errors" {
  val errs = Validation.required("alice", "username")
  assertTrue(Validation.isValid(errs), "non-empty string must be valid")
}

test "required: single-character string is valid" {
  val errs = Validation.required("a", "username")
  assertTrue(Validation.isValid(errs), "single char must be valid")
}

test "required: whitespace-only string is treated as non-empty" {
  // required only checks length; notBlank handles whitespace-only rejection
  val errs = Validation.required("   ", "username")
  assertTrue(Validation.isValid(errs), "required only rejects empty string, not blanks")
}

// ─── minLength ────────────────────────────────────────────────────────────────

test "minLength: string shorter than min returns error with code 'minLength'" {
  val errs = Validation.minLength("ab", "password", 8)
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "minLength", "code")
  }
}

test "minLength: string exactly at min returns no errors" {
  val errs = Validation.minLength("abcdefgh", "password", 8)
  assertTrue(Validation.isValid(errs), "length equal to min must be valid")
}

test "minLength: string longer than min returns no errors" {
  val errs = Validation.minLength("abcdefghi", "password", 8)
  assertTrue(Validation.isValid(errs), "length above min must be valid")
}

test "minLength: empty string fails min of 1" {
  val errs = Validation.minLength("", "tag", 1)
  assertTrue(not Validation.isValid(errs), "empty string must fail min of 1")
}

test "minLength: min of 0 accepts any string" {
  val errs = Validation.minLength("", "tag", 0)
  assertTrue(Validation.isValid(errs), "min of 0 must accept empty string")
}

// ─── maxLength ────────────────────────────────────────────────────────────────

test "maxLength: string longer than max returns error with code 'maxLength'" {
  val errs = Validation.maxLength("abcdefghijk", "bio", 10)
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "maxLength", "code")
  }
}

test "maxLength: string exactly at max returns no errors" {
  val errs = Validation.maxLength("abcdefghij", "bio", 10)
  assertTrue(Validation.isValid(errs), "length equal to max must be valid")
}

test "maxLength: empty string is within any positive max" {
  val errs = Validation.maxLength("", "bio", 10)
  assertTrue(Validation.isValid(errs), "empty string is within max of 10")
}

test "maxLength: max of 0 rejects any non-empty string" {
  val errs = Validation.maxLength("a", "code", 0)
  assertTrue(not Validation.isValid(errs), "non-empty string must fail max of 0")
}

test "maxLength: max of 0 accepts empty string" {
  val errs = Validation.maxLength("", "code", 0)
  assertTrue(Validation.isValid(errs), "empty string must pass max of 0")
}

// ─── exactLength ──────────────────────────────────────────────────────────────

test "exactLength: string shorter than target returns error with code 'exactLength'" {
  val errs = Validation.exactLength("abc", "zip", 5)
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "exactLength", "code")
  }
}

test "exactLength: string longer than target returns error" {
  val errs = Validation.exactLength("abcdef", "zip", 5)
  assertTrue(not Validation.isValid(errs), "string longer than target must fail")
}

test "exactLength: string of exact length returns no errors" {
  val errs = Validation.exactLength("abcde", "zip", 5)
  assertTrue(Validation.isValid(errs), "exact length must be valid")
}

test "exactLength: empty string with target 0 is valid" {
  val errs = Validation.exactLength("", "code", 0)
  assertTrue(Validation.isValid(errs), "empty string with target 0 must be valid")
}

test "exactLength: non-empty string with target 0 fails" {
  val errs = Validation.exactLength("x", "code", 0)
  assertTrue(not Validation.isValid(errs), "non-empty string with target 0 must fail")
}

// ─── notBlank ─────────────────────────────────────────────────────────────────

test "notBlank: empty string returns error with code 'notBlank'" {
  val errs = Validation.notBlank("", "title")
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "notBlank", "code")
  }
}

test "notBlank: whitespace-only string returns error" {
  val errs = Validation.notBlank("   ", "title")
  assertTrue(not Validation.isValid(errs), "whitespace-only must fail notBlank")
}

test "notBlank: tab-only string returns error" {
  val errs = Validation.notBlank("\t", "title")
  assertTrue(not Validation.isValid(errs), "tab-only string must fail notBlank")
}

test "notBlank: non-whitespace string returns no errors" {
  val errs = Validation.notBlank("hello", "title")
  assertTrue(Validation.isValid(errs), "non-blank string must pass")
}

test "notBlank: string with leading whitespace but non-whitespace content passes" {
  val errs = Validation.notBlank("  hello  ", "title")
  assertTrue(Validation.isValid(errs), "string with interior content must pass notBlank")
}

// ─── oneOf ────────────────────────────────────────────────────────────────────

test "oneOf: value in allowed list returns no errors" {
  val errs = Validation.oneOf("admin", "role", ["admin", "editor", "viewer"])
  assertTrue(Validation.isValid(errs), "value present in list must be valid")
}

test "oneOf: value not in list returns error with code 'oneOf'" {
  val errs = Validation.oneOf("superuser", "role", ["admin", "editor", "viewer"])
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "oneOf", "code")
  }
}

test "oneOf: comparison is case-sensitive" {
  val errs = Validation.oneOf("Admin", "role", ["admin", "editor"])
  assertTrue(not Validation.isValid(errs), "case mismatch must fail oneOf")
}

test "oneOf: single-element list accepts matching value" {
  val errs = Validation.oneOf("active", "status", ["active"])
  assertTrue(Validation.isValid(errs), "exact match in single-element list must pass")
}

test "oneOf: empty allowed list rejects every value" {
  val errs = Validation.oneOf("admin", "role", [])
  assertTrue(not Validation.isValid(errs), "empty allowed list must reject all values")
}

// ─── email ────────────────────────────────────────────────────────────────────

test "email: well-formed address returns no errors" {
  val errs = Validation.email("alice@example.com", "email")
  assertTrue(Validation.isValid(errs), "well-formed email must pass")
}

test "email: address with subdomain passes" {
  val errs = Validation.email("alice@mail.example.co.uk", "email")
  assertTrue(Validation.isValid(errs), "subdomain email must pass")
}

test "email: missing @ returns error with code 'email'" {
  val errs = Validation.email("aliceexample.com", "email")
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "email", "code")
  }
}

test "email: multiple @ signs fail" {
  val errs = Validation.email("a@@b.com", "email")
  assertTrue(not Validation.isValid(errs), "multiple @ signs must fail")
}

test "email: empty string fails" {
  val errs = Validation.email("", "email")
  assertTrue(not Validation.isValid(errs), "empty string must fail email validation")
}

test "email: missing domain fails" {
  val errs = Validation.email("alice@", "email")
  assertTrue(not Validation.isValid(errs), "missing domain must fail")
}

test "email: missing TLD (no dot in domain) fails" {
  val errs = Validation.email("alice@example", "email")
  assertTrue(not Validation.isValid(errs), "missing TLD must fail")
}

// ─── url ──────────────────────────────────────────────────────────────────────

test "url: http URL passes" {
  val errs = Validation.url("http://example.com", "website")
  assertTrue(Validation.isValid(errs), "http URL must pass")
}

test "url: https URL passes" {
  val errs = Validation.url("https://example.com/path?q=1", "website")
  assertTrue(Validation.isValid(errs), "https URL must pass")
}

test "url: ftp URL fails with code 'url'" {
  val errs = Validation.url("ftp://example.com", "website")
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "url", "code")
  }
}

test "url: plain hostname without scheme fails" {
  val errs = Validation.url("example.com", "website")
  assertTrue(not Validation.isValid(errs), "missing scheme must fail")
}

test "url: empty string fails" {
  val errs = Validation.url("", "website")
  assertTrue(not Validation.isValid(errs), "empty URL must fail")
}

// ─── minValue ─────────────────────────────────────────────────────────────────

test "minValue: value below min returns error with code 'minValue'" {
  val errs = Validation.minValue(4, "age", 18)
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "minValue", "code")
  }
}

test "minValue: value equal to min returns no errors" {
  val errs = Validation.minValue(18, "age", 18)
  assertTrue(Validation.isValid(errs), "value equal to min must pass")
}

test "minValue: value above min returns no errors" {
  val errs = Validation.minValue(25, "age", 18)
  assertTrue(Validation.isValid(errs), "value above min must pass")
}

test "minValue: negative min accepts negative value" {
  val errs = Validation.minValue(-5, "temp", -10)
  assertTrue(Validation.isValid(errs), "value above negative min must pass")
}

test "minValue: zero min rejects negative value" {
  val errs = Validation.minValue(-1, "count", 0)
  assertTrue(not Validation.isValid(errs), "negative value must fail min of 0")
}

// ─── maxValue ─────────────────────────────────────────────────────────────────

test "maxValue: value above max returns error with code 'maxValue'" {
  val errs = Validation.maxValue(200, "age", 150)
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "maxValue", "code")
  }
}

test "maxValue: value equal to max returns no errors" {
  val errs = Validation.maxValue(150, "age", 150)
  assertTrue(Validation.isValid(errs), "value equal to max must pass")
}

test "maxValue: value below max returns no errors" {
  val errs = Validation.maxValue(42, "age", 150)
  assertTrue(Validation.isValid(errs), "value below max must pass")
}

test "maxValue: negative max rejects zero" {
  val errs = Validation.maxValue(0, "offset", -1)
  assertTrue(not Validation.isValid(errs), "zero must fail negative max")
}

test "maxValue: max of zero accepts negative value" {
  val errs = Validation.maxValue(-5, "offset", 0)
  assertTrue(Validation.isValid(errs), "negative value must pass max of 0")
}

// ─── rangeValue ───────────────────────────────────────────────────────────────

test "rangeValue: value within range returns no errors" {
  val errs = Validation.rangeValue(50, "score", 0, 100)
  assertTrue(Validation.isValid(errs), "value in range must pass")
}

test "rangeValue: value at lower bound is valid" {
  val errs = Validation.rangeValue(0, "score", 0, 100)
  assertTrue(Validation.isValid(errs), "lower bound must be valid (inclusive)")
}

test "rangeValue: value at upper bound is valid" {
  val errs = Validation.rangeValue(100, "score", 0, 100)
  assertTrue(Validation.isValid(errs), "upper bound must be valid (inclusive)")
}

test "rangeValue: value below lower bound returns error with code 'rangeValue'" {
  val errs = Validation.rangeValue(-1, "score", 0, 100)
  assertTrue(errs.length == 1, "expected one error")
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError should not be None")
    case Some(e) -> assertEqual(e.code, "rangeValue", "code")
  }
}

test "rangeValue: value above upper bound returns error" {
  val errs = Validation.rangeValue(101, "score", 0, 100)
  assertTrue(not Validation.isValid(errs), "value above upper bound must fail")
}

// ─── combine ──────────────────────────────────────────────────────────────────

test "combine: two empty lists gives an empty list" {
  val errs = Validation.combine([], [])
  assertTrue(Validation.isValid(errs), "combine of two empty lists must be valid")
}

test "combine: error in first list is included in result" {
  val a = Validation.required("", "name")
  val b: [ValidationError] = []
  val errs = Validation.combine(a, b)
  assertTrue(errs.length == 1, "result must contain the single error from a")
}

test "combine: error in second list is included in result" {
  val a: [ValidationError] = []
  val b = Validation.required("", "email")
  val errs = Validation.combine(a, b)
  assertTrue(errs.length == 1, "result must contain the single error from b")
}

test "combine: errors from both lists are combined" {
  val a = Validation.required("", "name")
  val b = Validation.required("", "email")
  val errs = Validation.combine(a, b)
  assertTrue(errs.length == 2, "result must contain both errors")
}

// ─── all ──────────────────────────────────────────────────────────────────────

test "all: empty input list gives an empty error list" {
  val errs = Validation.all([])
  assertTrue(Validation.isValid(errs), "all of empty input must be valid")
}

test "all: all-passing validators give an empty error list" {
  val errs = Validation.all([
    Validation.required("alice", "name"),
    Validation.minLength("alice", "name", 2),
    Validation.maxLength("alice", "name", 100),
  ])
  assertTrue(Validation.isValid(errs), "all-passing validators must produce no errors")
}

test "all: one failing validator produces its error in the result" {
  val errs = Validation.all([
    Validation.required("alice", "name"),
    Validation.minLength("", "bio", 1),
  ])
  assertTrue(errs.length == 1, "one failing validator must yield one error")
}

test "all: multiple failing validators accumulate errors" {
  val errs = Validation.all([
    Validation.required("", "name"),
    Validation.required("", "email"),
    Validation.minLength("x", "bio", 10),
  ])
  assertTrue(errs.length == 3, "three failing validators must yield three errors")
}

// ─── isValid / firstError ─────────────────────────────────────────────────────

test "isValid: returns true for empty list" {
  assertTrue(Validation.isValid([]), "isValid on empty list must be true")
}

test "isValid: returns false for non-empty list" {
  val errs = Validation.required("", "field")
  assertTrue(not Validation.isValid(errs), "isValid on non-empty list must be false")
}

test "firstError: returns None for empty list" {
  match Validation.firstError([]) {
    case None    -> ()
    case Some(_) -> assertTrue(false, "firstError on empty list must be None")
  }
}

test "firstError: returns the first error in a non-empty list" {
  val errs = Validation.all([
    Validation.required("", "name"),
    Validation.required("", "email"),
  ])
  match Validation.firstError(errs) {
    case None    -> assertTrue(false, "firstError must not be None")
    case Some(e) -> assertEqual(e.field, "name", "first error field must be 'name'")
  }
}

// ─── toResult ─────────────────────────────────────────────────────────────────

test "toResult: empty errors list returns Ok(value)" {
  val result = Validation.toResult(42, [])
  match result {
    case Ok(v)   -> assertEqualInt(v, 42, "value in Ok")
    case Err(_)  -> assertTrue(false, "expected Ok, got Err")
  }
}

test "toResult: non-empty errors list returns Err(errors)" {
  val errs = Validation.required("", "name")
  val result = Validation.toResult("ignored", errs)
  match result {
    case Ok(_)   -> assertTrue(false, "expected Err, got Ok")
    case Err(es) -> assertTrue(es.length == 1, "Err must contain the one error")
  }
}

test "toResult: multiple errors are all present in Err" {
  val errs = Validation.all([
    Validation.required("", "name"),
    Validation.required("", "email"),
  ])
  val result = Validation.toResult("ignored", errs)
  match result {
    case Ok(_)   -> assertTrue(false, "expected Err")
    case Err(es) -> assertTrue(es.length == 2, "both errors must be in Err")
  }
}
