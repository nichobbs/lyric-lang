//! stdlib/tests/json_tests.l — Tests for Std.Json (BCL-backed JSON).
//!
//! Covers: parsing scalars (string, int, bool, null via valueKind),
//! object property access (getProperty, tryGetProperty), array enumeration,
//! encodeString, getRawText, and valueKind.
package Std.Json.Tests

// System.Text.Json.JsonValueKind enum values used in valueKind() assertions:
//   Undefined=0  Object=1  Array=2  String=3  Number=4  True=5  False=6  Null=7
import Std.Core
import Std.Json
import Std.Testing

func testParseString(): Unit {
  val doc = parseJson("\"hello\"")
  val root = rootElement(doc)
  assertTrue(valueKind(root) == 3, "string valueKind is 3")
  assertTrue(getString(root) == "hello", "string value")
}

func testParseInt(): Unit {
  val doc = parseJson("42")
  val root = rootElement(doc)
  assertTrue(valueKind(root) == 4, "number valueKind is 4")
  assertEqualInt(getInt32(root), 42, "int32 value")
}

func testParseBool(): Unit {
  val docT = parseJson("true")
  val rootT = rootElement(docT)
  assertTrue(valueKind(rootT) == 5, "true valueKind is 5")
  assertTrue(getBoolean(rootT), "true value")

  val docF = parseJson("false")
  val rootF = rootElement(docF)
  assertTrue(valueKind(rootF) == 6, "false valueKind is 6")
  assertTrue(not getBoolean(rootF), "false value")
}

func testParseNull(): Unit {
  val doc = parseJson("null")
  val root = rootElement(doc)
  assertTrue(valueKind(root) == 7, "null valueKind is 7")
}

func testObjectGetProperty(): Unit {
  val doc = parseJson("{\"name\":\"Alice\",\"age\":30}")
  val root = rootElement(doc)
  val name = getProperty(root, "name")
  assertTrue(getString(name) == "Alice", "name property")
  val age = getProperty(root, "age")
  assertEqualInt(getInt32(age), 30, "age property")
}

func testTryGetProperty(): Unit {
  val doc = parseJson("{\"x\":1}")
  val root = rootElement(doc)
  match tryGetProperty(root, "x") {
    case Some(e) -> assertEqualInt(getInt32(e), 1, "tryGetProperty x == 1")
    case None -> assertTrue(false, "x should be present")
  }
  match tryGetProperty(root, "y") {
    case Some(_) -> assertTrue(false, "y should be absent")
    case None -> assertTrue(true, "y absent")
  }
}

func testEncodeString(): Unit {
  // Simple string: no special chars — result is exactly "hello".
  val simple = encodeString("hello")
  assertTrue(simple == "\"hello\"", "simple string JSON-encoded")
  // System.Text.Json.JsonEncodedText uses " for double-quote (HTML-safe
  // encoding), so we just check the structural wrapping rather than the exact
  // escape sequence.
  val withQuote = encodeString("a\"b")
  assertTrue(withQuote.startsWith("\""), "encoded starts with double-quote")
  assertTrue(withQuote.endsWith("\""), "encoded ends with double-quote")
  assertTrue(withQuote.length > 3, "encoded has content beyond wrapper quotes")
}

func testArrayEnumeration(): Unit {
  val doc = parseJson("[10, 20, 30]")
  val root = rootElement(doc)
  assertTrue(valueKind(root) == 2, "array valueKind is 2")
  var en = enumerateArray(root)
  var count = 0
  while arrayMoveNext(en) {
    val elem = arrayCurrent(en)
    assertTrue(valueKind(elem) == 4, "array element is number")
    count = count + 1
  }
  assertEqualInt(count, 3, "array has 3 elements")
}

func testObjectEnumeration(): Unit {
  val doc = parseJson("{\"a\":1,\"b\":2}")
  val root = rootElement(doc)
  assertTrue(valueKind(root) == 1, "object valueKind is 1")
  var en = enumerateObject(root)
  var count = 0
  while objectMoveNext(en) {
    val prop = objectCurrent(en)
    val name = propertyName(prop)
    assertTrue(name == "a" or name == "b", "property name is a or b")
    count = count + 1
  }
  assertEqualInt(count, 2, "object has 2 properties")
}

func testGetRawText(): Unit {
  val doc = parseJson("{\"nested\":{\"k\":99}}")
  val root = rootElement(doc)
  val sub = getProperty(root, "nested")
  val raw = getRawText(sub)
  assertTrue(raw.contains("k"), "raw text contains k")
  assertTrue(raw.contains("99"), "raw text contains 99")
}

func testTryGetInt(): Unit {
  // Test 1: tryGetInt on a numeric value should return Some
  val doc1 = parseJson("{\"num\":42}")
  val root1 = rootElement(doc1)
  val num = getProperty(root1, "num")
  match tryGetInt(num) {
    case Some(v) -> assertEqualInt(v, 42, "tryGetInt extracts numeric value")
    case None -> assertTrue(false, "tryGetInt should extract numeric value")
  }

  // Test 2: tryGetInt on a string value should return None (not throw)
  val doc2 = parseJson("{\"str\":\"hello\"}")
  val root2 = rootElement(doc2)
  val str = getProperty(root2, "str")
  match tryGetInt(str) {
    case Some(_) -> assertTrue(false, "tryGetInt should not extract int from string")
    case None -> assertTrue(true, "correctly returned None for non-numeric value")
  }
}

func testTryGetLong(): Unit {
  // Test 1: tryGetLong on a numeric value should return Some
  val doc1 = parseJson("{\"num\":12345}")
  val root1 = rootElement(doc1)
  val num = getProperty(root1, "num")
  match tryGetLong(num) {
    case Some(v) -> assertTrue(v == 12345, "tryGetLong extracts numeric value")
    case None -> assertTrue(false, "tryGetLong should extract numeric value")
  }

  // Test 2: tryGetLong on a string value should return None (not throw)
  val doc2 = parseJson("{\"str\":\"hello\"}")
  val root2 = rootElement(doc2)
  val str = getProperty(root2, "str")
  match tryGetLong(str) {
    case Some(_) -> assertTrue(false, "tryGetLong should not extract long from string")
    case None -> assertTrue(true, "correctly returned None for non-numeric value")
  }
}

func main(): Unit {
  testParseString()
  testParseInt()
  testParseBool()
  testParseNull()
  testObjectGetProperty()
  testTryGetProperty()
  testEncodeString()
  testArrayEnumeration()
  testObjectEnumeration()
  testGetRawText()
  testTryGetInt()
  testTryGetLong()
  println("json_tests: ok")
}
