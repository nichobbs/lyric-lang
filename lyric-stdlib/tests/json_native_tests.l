//! Std.Json on `--target native`: the document API over the pure-Lyric kernel
//! twin (`_kernel_native/json_host.l`, which parses with `Std.Yaml.parseJson`).
//! The cases of `json_tests.l` that need no catchable panic, since native has
//! no unwinding (D-N-003).
//!
//!   lyric test --target native lyric-stdlib/tests/json_native_tests.l
@test_module
package Std.Json.NativeTests

import Std.Core
import Std.Collections
import Std.Json
import Std.Testing

test "an object's properties read back by type" {
  val doc = parseJson("{\"name\":\"lyric\",\"count\":42,\"big\":9007199254740993,\"ratio\":2.5,\"on\":true}")
  val root = rootElement(doc)
  assertEqual(getString(getProperty(root, "name")), "lyric", "string property")
  assertEqualInt(getInt32(getProperty(root, "count")), 42, "int32 property")
  assertEqualLong(getInt64(getProperty(root, "big")), 9007199254740993i64, "int64 keeps its exact value")
  assertTrue(getDouble(getProperty(root, "ratio")) == 2.5, "double property")
  assertTrue(getBoolean(getProperty(root, "on")), "boolean property")
  disposeJson(doc)
}

test "tryGetProperty and hasProperty report a missing name without failing" {
  val doc = parseJson("{\"a\":1}")
  val root = rootElement(doc)
  assertTrue(hasProperty(root, "a"), "a present property")
  assertFalse(hasProperty(root, "b"), "a missing property")
  match tryGetProperty(root, "b") {
    case Some(_) -> assertTrue(false, "b should be missing")
    case None -> assertTrue(true, "None for a missing property")
  }
}

test "number kinds are told apart" {
  val doc = parseJson("[1, 3000000000, 1.5]")
  val root = rootElement(doc)
  var cur = enumerateArray(root)
  assertTrue(arrayMoveNext(cur), "first element")
  val a = arrayCurrent(cur)
  assertTrue(isJsonInt32(a), "1 fits Int32")
  assertTrue(arrayMoveNext(cur), "second element")
  val b = arrayCurrent(cur)
  assertFalse(isJsonInt32(b), "3000000000 does not fit Int32")
  assertTrue(isJsonInt64(b), "3000000000 fits Int64")
  assertTrue(arrayMoveNext(cur), "third element")
  assertTrue(isJsonDouble(arrayCurrent(cur)), "1.5 is a double")
  assertFalse(arrayMoveNext(cur), "no fourth element")
}

test "an array and an object enumerate in order" {
  val doc = parseJson("{\"xs\":[10,20,30],\"k\":\"v\"}")
  val root = rootElement(doc)
  var total = 0
  var cur = enumerateArray(getProperty(root, "xs"))
  while arrayMoveNext(cur) {
    total = total + getInt32(arrayCurrent(cur))
  }
  assertEqualInt(total, 60, "array elements sum")
  var names = ""
  var oc = enumerateObject(root)
  while objectMoveNext(oc) {
    names = names + propertyName(objectCurrent(oc)) + ","
  }
  assertEqual(names, "xs,k,", "object properties in document order")
}

test "tryParseJson reports malformed input as an error value" {
  match tryParseJson("{\"a\":") {
    case Ok(_) -> assertTrue(false, "truncated input must not parse")
    case Err(msg) -> assertTrue(msg.length > 0, "an error message")
  }
  match tryParseJson("[1,2") {
    case Ok(_) -> assertTrue(false, "unterminated array must not parse")
    case Err(_) -> assertTrue(true, "error for an unterminated array")
  }
}

test "encodeString escapes quotes, backslashes and controls" {
  assertEqual(encodeString("a\"b\\c\nd"), "\"a\\\"b\\\\c\\nd\"", "quote, backslash, newline")
  assertEqual(encodeString("plain"), "\"plain\"", "plain text is just quoted")
}

test "getRawText re-serialises an element" {
  val doc = parseJson("{\"s\":\"hi\",\"n\":[1,2]}")
  val root = rootElement(doc)
  assertEqual(getRawText(getProperty(root, "s")), "\"hi\"", "a string keeps its quotes")
  assertEqual(getRawText(getProperty(root, "n")), "[1,2]", "an array in canonical form")
}
