//! tests/json_tests.l — test suite for JsonRpc.Json.
//! Covers: round-trips for every JsonValue case, string escaping both
//! directions (\uXXXX, surrogate pairs, control characters), strict-number
//! parsing (leading zeros, bare '.'/'e' rejected), depth-limit enforcement,
//! duplicate-key preservation with last-wins accessors, i64 round-trip
//! exactness, and malformed-input rejection (truncated, trailing garbage,
//! bad escapes, lone surrogates).
@test_module
package JsonRpc.Json.JsonTests

import Std.Core
import Std.Testing
import JsonRpc.Json

// `Option[T] == Option[T]` does not compare structurally on the current
// self-hosted MSIL backend (reproduced in isolation: two `Some(value = 1)`
// Option[Int] values built independently compare `false` with `==`) — so
// every `Option`-valued assertion below goes through `match` instead of
// `== Some(...)`. Filed upstream; see the README's "Known upstream issues"
// section.
func assertSomeLong(o: in Option[Long], expected: in Long, label: in String): Unit {
  match o {
    case Some(n) -> assertTrue(n == expected, label)
    case None -> assertTrue(false, label + " (expected Some, got None)")
  }
}

func assertSomeBool(o: in Option[Bool], expected: in Bool, label: in String): Unit {
  match o {
    case Some(b) -> assertTrue(b == expected, label)
    case None -> assertTrue(false, label + " (expected Some, got None)")
  }
}

// Concrete (non-generic) per-type helpers, deliberately NOT a single
// `assertIsSome[T]`/`assertIsNone[T]` generic pair: an earlier version of
// this file used generics here and hit the same class of bug from a
// different angle — calling one generic helper with several different
// concrete `Option[T]` instantiations across this file intermittently
// produced "match not exhaustive" at *runtime* on a call that had compiled
// and passed moments earlier in a previous `lyric test` invocation (the
// monomorphizer's specialization appears to collide non-deterministically
// across instantiations sharing one compilation unit — same underlying
// class of bug as the `isSome`/`isNone` note above, but reproducing on
// *both* backends here, and only sometimes). Fully concrete, single-use
// helpers have no shared generic specialization to collide over. Filed
// upstream; see the README's "Known upstream issues" section.
func assertIsNoneString(o: in Option[String], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some)")
  }
}

func assertIsNoneBool(o: in Option[Bool], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some)")
  }
}

func assertIsNoneFloat(o: in Option[Double], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some)")
  }
}

func assertIsSomeArray(o: in Option[List[JsonValue]], label: in String): Unit {
  match o {
    case Some(v) -> ()
    case None -> assertTrue(false, label + " (expected Some, got None)")
  }
}

func assertIsNoneArray(o: in Option[List[JsonValue]], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some)")
  }
}

func assertIsSomeObjectFields(o: in Option[List[JsonField]], label: in String): Unit {
  match o {
    case Some(v) -> ()
    case None -> assertTrue(false, label + " (expected Some, got None)")
  }
}

func assertIsNoneObjectFields(o: in Option[List[JsonField]], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some)")
  }
}

func assertIsNoneValue(o: in Option[JsonValue], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some)")
  }
}

func assertIsNoneLong(o: in Option[Long], label: in String): Unit {
  match o {
    case None -> ()
    case Some(v) -> assertTrue(false, label + " (expected None, got Some)")
  }
}

// ── Round-trips: primitives ─────────────────────────────────────────────────
test "parseValue: null" {
  match parseValue("null") {
    case Ok(v) -> assertTrue(isNull(v), "parses to JNull")
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
  }
}

test "parseValue: true / false" {
  match parseValue("true") {
    case Ok(v) -> assertSomeBool(asBool(v), true, "true")
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
  }
  match parseValue("false") {
    case Ok(v) -> assertSomeBool(asBool(v), false, "false")
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
  }
}

test "writeValue: null / true / false" {
  assertEqual(writeValue(JNull), "null", "null")
  assertEqual(writeValue(JBool(value = true)), "true", "true")
  assertEqual(writeValue(JBool(value = false)), "false", "false")
}

// ── Integers: i64 round-trip exactness ──────────────────────────────────────
test "JInt round-trips i64 boundary values exactly" {
  val cases: List[Long] = newList()
  cases.add(0i64)
  cases.add(1i64)
  cases.add(0 - 1i64)
  cases.add(9223372036854775807i64)
  // Long.MaxValue
  cases.add(0 - 9223372036854775807i64 - 1i64)
  // Long.MinValue (written this way: the literal -9223372036854775808 has no
  // positive counterpart representable before negation)
  var i = 0
  while i < cases.count {
    val n = cases[i]
    val text = writeValue(JInt(value = n))
    match parseValue(text) {
      case Err(e) -> assertTrue(false, "round-trip parse failed for " + text + ": " + e.message())
      case Ok(v) -> match asInt(v) { case None -> assertTrue(false, "expected JInt for " + text); case Some(got) -> assertTrue(got == n, "round-trip mismatch: wrote " + text + ", got back a different value") }
    }
    i = i + 1
  }
}

test "an integer literal beyond i64 range parses as JFloat, not a silently wrapped JInt" {
  // One digit beyond Long.MaxValue (9223372036854775807).
  match parseValue("9223372036854775808") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> {
      match asFloat(v) {
        case Some(f) -> ()
        case None -> assertTrue(false, "classified as JFloat")
      }
      match asInt(v) {
        case None -> ()
        case Some(n) -> assertTrue(false, "not classified as JInt")
      }
    }
  }
}

test "JFloat round-trips ordinary values" {
  match parseValue("3.5") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asFloat(v) { case Some(f) -> assertTrue(f == 3.5, "3.5"); case None -> assertTrue(false, "expected JFloat") }
  }
  match parseValue("-0.25") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asFloat(v) { case Some(f) -> assertTrue(f == 0.0 - 0.25, "-0.25"); case None -> assertTrue(false, "expected JFloat") }
  }
}

test "an integer written with an exponent classifies as JFloat" {
  match parseValue("2e3") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asFloat(v) { case Some(f) -> (); case None -> assertTrue(false, "2e3 is a JFloat") }
  }
}

// ── Strict number grammar ───────────────────────────────────────────────────
test "leading zeros are rejected" {
  match parseValue("01") {
    case Ok(v) -> assertTrue(false, "expected rejection of '01'")
    case Err(e) -> ()
  }
  match parseValue("00") {
    case Ok(v) -> assertTrue(false, "expected rejection of '00'")
    case Err(e) -> ()
  }
  match parseValue("0") {
    case Err(e) -> assertTrue(false, "'0' alone must be accepted: " + e.message())
    case Ok(v) -> assertSomeLong(asInt(v), 0i64, "'0' parses to 0")
  }
  match parseValue("-0") {
    case Err(e) -> assertTrue(false, "'-0' must be accepted: " + e.message())
    case Ok(v) -> match asInt(v) { case Some(n) -> (); case None -> assertTrue(false, "'-0' is a JInt") }
  }
}

test "a bare '.' with no digits before or after is rejected" {
  match parseValue("1.") {
    case Ok(v) -> assertTrue(false, "expected rejection of '1.'")
    case Err(e) -> ()
  }
  match parseValue(".5") {
    case Ok(v) -> assertTrue(false, "expected rejection of '.5' (not a JSON value at all)")
    case Err(e) -> ()
  }
}

test "an exponent with no digits is rejected" {
  match parseValue("1e") {
    case Ok(v) -> assertTrue(false, "expected rejection of '1e'")
    case Err(e) -> ()
  }
  match parseValue("1e+") {
    case Ok(v) -> assertTrue(false, "expected rejection of '1e+'")
    case Err(e) -> ()
  }
}

test "a bare minus with no digits is rejected" {
  match parseValue("-") {
    case Ok(v) -> assertTrue(false, "expected rejection of '-'")
    case Err(e) -> ()
  }
}

// ── Strings: escapes, both directions ───────────────────────────────────────
test "parseValue: basic string escapes" {
  match parseValue("\"a\\\"b\\\\c\\/d\\ne\\rf\\tg\\bh\\fi\"") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asString(v) { case None -> assertTrue(false, "expected JString"); case Some(s) -> assertEqual(s, "a\"b\\c/d\ne\rf\tg\u{0008}h\u{000c}i", "all named escapes decode correctly") }
  }
}

test "writeValue: control characters are escaped" {
  val s = "a\nb\rc\td\u{0008}e\u{000c}f\u{0000}g\u{001f}h"
  val text = writeValue(JString(value = s))
  assertEqual(
    text,
    "\"a\\nb\\rc\\td\\be\\ff\\u0000g\\u001fh\"",
    "named escapes for \\n\\r\\t\\b\\f, \\u00XX for other controls"
  )
}

test "writeValue: quote and backslash are escaped" {
  assertEqual(writeValue(JString(value = "a\"b\\c")), "\"a\\\"b\\\\c\"", "quote and backslash escaped")
}

test "writeValue: forward slash and high-Unicode are NOT escaped (compact writer)" {
  assertEqual(writeValue(JString(value = "a/b")), "\"a/b\"", "forward slash not escaped")
  assertEqual(writeValue(JString(value = "café")), "\"café\"", "non-ASCII left as literal UTF-16, not \\u-escaped")
}

test "parseValue: \\uXXXX escapes decode to the exact code unit" {
  match parseValue("\"\\u0041\\u00e9\"") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asString(v) { case Some(s) -> assertEqual(s, "Aé", "\\u0041 = 'A', \\u00e9 = 'é'"); case None -> assertTrue(false, "expected JString") }
  }
}

test "parseValue: a valid surrogate pair decodes to one supplementary-plane character" {
  // U+1F600 GRINNING FACE = surrogate pair 😀.
  match parseValue("\"\\uD83D\\uDE00\"") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asString(v) { case Some(s) -> assertEqual(s, "😀", "surrogate pair decodes to the emoji"); case None -> assertTrue(false, "expected JString") }
  }
}

test "writeValue then parseValue round-trips a supplementary-plane character" {
  val original = "before 😀 after"
  val text = writeValue(JString(value = original))
  match parseValue(text) {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asString(v) { case Some(s) -> assertEqual(s, original, "round-trips exactly"); case None -> assertTrue(false, "expected JString") }
  }
}

// ── Malformed input rejection ────────────────────────────────────────────────
test "a raw (unescaped) control character in a string is rejected" {
  match parseValue("\"a\tb\"") {
    case Ok(v) -> assertTrue(false, "expected rejection of a raw tab character")
    case Err(e) -> ()
  }
}

test "a truncated string (missing closing quote) is rejected" {
  match parseValue("\"abc") {
    case Ok(v) -> assertTrue(false, "expected rejection of an unterminated string")
    case Err(e) -> ()
  }
}

test "a truncated array (missing closing bracket) is rejected" {
  match parseValue("[1,2") {
    case Ok(v) -> assertTrue(false, "expected rejection of a truncated array")
    case Err(e) -> ()
  }
}

test "a truncated object (missing closing brace) is rejected" {
  match parseValue("{\"a\":1") {
    case Ok(v) -> assertTrue(false, "expected rejection of a truncated object")
    case Err(e) -> ()
  }
}

test "trailing garbage after a valid value is rejected" {
  match parseValue("1 2") {
    case Ok(v) -> assertTrue(false, "expected rejection of trailing garbage")
    case Err(e) -> ()
  }
  match parseValue("{}garbage") {
    case Ok(v) -> assertTrue(false, "expected rejection of trailing garbage after an object")
    case Err(e) -> ()
  }
}

test "empty input is rejected" {
  match parseValue("") {
    case Ok(v) -> assertTrue(false, "expected rejection of empty input")
    case Err(e) -> ()
  }
  match parseValue("   ") {
    case Ok(v) -> assertTrue(false, "expected rejection of all-whitespace input")
    case Err(e) -> ()
  }
}

test "an invalid escape sequence is rejected" {
  match parseValue("\"\\x41\"") {
    case Ok(v) -> assertTrue(false, "expected rejection of \\x (not a JSON escape)")
    case Err(e) -> ()
  }
}

test "a truncated \\uXXXX escape (fewer than 4 hex digits) is rejected" {
  match parseValue("\"\\u12\"") {
    case Ok(v) -> assertTrue(false, "expected rejection of a short \\u escape")
    case Err(e) -> ()
  }
}

test "a non-hex digit inside \\uXXXX is rejected" {
  match parseValue("\"\\u12zz\"") {
    case Ok(v) -> assertTrue(false, "expected rejection of a non-hex \\u escape")
    case Err(e) -> ()
  }
}

test "trailing comma in an array is rejected" {
  match parseValue("[1,2,]") {
    case Ok(v) -> assertTrue(false, "expected rejection of a trailing comma")
    case Err(e) -> ()
  }
}

test "trailing comma in an object is rejected" {
  match parseValue("{\"a\":1,}") {
    case Ok(v) -> assertTrue(false, "expected rejection of a trailing comma")
    case Err(e) -> ()
  }
}

test "single-quoted strings are rejected (JSON has none)" {
  match parseValue("'abc'") {
    case Ok(v) -> assertTrue(false, "expected rejection of a single-quoted string")
    case Err(e) -> ()
  }
}

test "an unquoted object key is rejected" {
  match parseValue("{a:1}") {
    case Ok(v) -> assertTrue(false, "expected rejection of an unquoted key")
    case Err(e) -> ()
  }
}

// ── Lone surrogate rejection ─────────────────────────────────────────────────
test "a lone high surrogate escape (no following low surrogate) is rejected" {
  match parseValue("\"\\uD800\"") {
    case Ok(v) -> assertTrue(false, "expected rejection of a lone high surrogate")
    case Err(e) -> ()
  }
  match parseValue("\"\\uD800x\"") {
    case Ok(v) -> assertTrue(false, "expected rejection: high surrogate followed by a plain char, not a low surrogate")
    case Err(e) -> ()
  }
}

test "a lone low surrogate escape (no preceding high surrogate) is rejected" {
  match parseValue("\"\\uDC00\"") {
    case Ok(v) -> assertTrue(false, "expected rejection of a lone low surrogate")
    case Err(e) -> ()
  }
}

test "two high surrogates in a row is rejected (first one is never paired)" {
  match parseValue("\"\\uD800\\uD800\"") {
    case Ok(v) -> assertTrue(false, "expected rejection")
    case Err(e) -> ()
  }
}

// ── Depth limit ──────────────────────────────────────────────────────────────
func nestedArray(depth: in Int): String {
  var s = ""
  var i = 0
  while i < depth {
    s = s + "["
    i = i + 1
  }
  s = s + "0"
  i = 0
  while i < depth {
    s = s + "]"
    i = i + 1
  }
  s
}

test "an array nested within the depth limit parses" {
  val text = nestedArray(10)
  match parseValueWithDepthLimit(text, 20) {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> ()
  }
}

test "an array nested beyond the depth limit is rejected" {
  val text = nestedArray(50)
  match parseValueWithDepthLimit(text, 10) {
    case Ok(v) -> assertTrue(false, "expected DepthExceeded rejection")
    case Err(e) -> ()
  }
}

test "the default depth limit (128) rejects deeper nesting" {
  val text = nestedArray(200)
  match parseValue(text) {
    case Ok(v) -> assertTrue(false, "expected DepthExceeded rejection at the default limit")
    case Err(e) -> ()
  }
}

// ── Arrays and objects ───────────────────────────────────────────────────────
test "parseValue then writeValue round-trips an array" {
  match parseValue("[1,\"two\",true,null,[3,4]]") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> {
      match asArray(v) {
        case None -> assertTrue(false, "expected JArray")
        case Some(items) -> assertEqualInt(items.count, 5, "5 top-level items")
      }
      assertEqual(writeValue(v), "[1,\"two\",true,null,[3,4]]", "compact round-trip")
    }
  }
}

test "empty array and empty object round-trip" {
  assertEqual(writeValue(JArray(items = newList())), "[]", "empty array")
  assertEqual(writeValue(JObject(fields = newList())), "{}", "empty object")
  match parseValue("[]") {
    case Ok(v) -> {
      val r: Option[List[JsonValue]] = asArray(v)
      assertIsSomeArray(r, "empty array parses")
    }
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
  }
  match parseValue("{}") {
    case Ok(v) -> {
      val r: Option[List[JsonField]] = asObject(v)
      assertIsSomeObjectFields(r, "empty object parses")
    }
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
  }
}

test "parseValue then writeValue round-trips an object, preserving field order" {
  match parseValue("{\"b\":1,\"a\":2}") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> assertEqual(writeValue(v), "{\"b\":1,\"a\":2}", "insertion order preserved, not sorted")
  }
}

test "whitespace between tokens is insignificant" {
  match parseValue(" { \"a\" : 1 , \"b\" : [ 1 , 2 ] } ") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> {
      assertSomeLong(getInt(v, "a"), 1i64, "a = 1")
      match getArray(v, "b") {
        case Some(items) -> assertEqualInt(items.count, 2, "b has 2 items")
        case None -> assertTrue(false, "expected b to be an array")
      }
    }
  }
}

// ── Duplicate keys: preserved on parse, last-wins on access ────────────────
test "duplicate object keys are preserved (not rejected, not deduplicated)" {
  match parseValue("{\"a\":1,\"a\":2}") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> match asObject(v) { case None -> assertTrue(false, "expected JObject"); case Some(fields) -> assertEqualInt(fields.count, 2, "both occurrences kept") }
  }
}

test "getField resolves duplicate keys last-wins" {
  match parseValue("{\"a\":1,\"a\":2,\"a\":3}") {
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message())
    case Ok(v) -> assertSomeLong(getInt(v, "a"), 3i64, "last occurrence (3) wins")
  }
}

// ── Accessor helpers ─────────────────────────────────────────────────────────
test "asString / asBool / asInt / asFloat / asArray / asObject reject the wrong shape" {
  val n = JInt(value = 1i64)
  val rString: Option[String] = asString(n)
  assertIsNoneString(rString, "asString on JInt")
  val rBool: Option[Bool] = asBool(n)
  assertIsNoneBool(rBool, "asBool on JInt")
  val rFloat: Option[Double] = asFloat(n)
  assertIsNoneFloat(rFloat, "asFloat on JInt (no JInt->JFloat coercion)")
  val rArray: Option[List[JsonValue]] = asArray(n)
  assertIsNoneArray(rArray, "asArray on JInt")
  val rObject: Option[List[JsonField]] = asObject(n)
  assertIsNoneObjectFields(rObject, "asObject on JInt")
  assertSomeLong(asInt(n), 1i64, "asInt on JInt succeeds")
}

test "getField / getString / getInt / getBool / getFloat return None for a missing key" {
  val obj = JObject(fields = newList())
  val rField: Option[JsonValue] = getField(obj, "missing")
  assertIsNoneValue(rField, "getField")
  val rString: Option[String] = getString(obj, "missing")
  assertIsNoneString(rString, "getString")
  val rInt: Option[Long] = getInt(obj, "missing")
  assertIsNoneLong(rInt, "getInt")
  val rBool: Option[Bool] = getBool(obj, "missing")
  assertIsNoneBool(rBool, "getBool")
  val rFloat: Option[Double] = getFloat(obj, "missing")
  assertIsNoneFloat(rFloat, "getFloat")
}

test "getField on a non-object value returns None" {
  val r: Option[JsonValue] = getField(JInt(value = 1i64), "a")
  assertIsNoneValue(r, "getField on a JInt")
}
