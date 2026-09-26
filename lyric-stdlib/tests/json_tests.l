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

func testTryParseJson(): Unit {
  // Valid JSON
  match tryParseJson("{\"x\":1}") {
    case Ok(doc) -> {
      val root = rootElement(doc)
      assertEqualInt(getInt32(getProperty(root, "x")), 1, "tryParseJson parses valid JSON")
      disposeJson(doc)
    }
    case Err(msg) -> assertTrue(false, "tryParseJson failed on valid JSON: " + msg)
  }

  // Malformed JSON
  match tryParseJson("{ malformed }") {
    case Ok(doc) -> {
      disposeJson(doc)
      assertTrue(false, "tryParseJson should have failed on malformed JSON")
    }
    case Err(msg) -> {
      assertTrue(msg.length > 0, "tryParseJson returned error for malformed JSON: " + msg)
    }
  }

  // Empty JSON
  match tryParseJson("") {
    case Ok(doc) -> {
      disposeJson(doc)
      assertTrue(false, "tryParseJson should have failed on empty string")
    }
    case Err(msg) -> {
      assertTrue(msg.length > 0, "tryParseJson returned error for empty string: " + msg)
    }
  }
}

// #7251: the throwing getters are guarded by checked preconditions, and the
// @generate(Json) field readers fail closed on untrusted bodies.
func testGetterPreconditions(): Unit {
  val doc = parseJson("{\"n\": 3000000000, \"s\": \"x\", \"b\": true}")
  val root = rootElement(doc)
  assertTrue(hasProperty(root, "s"), "hasProperty finds s")
  assertTrue(not hasProperty(root, "missing"), "hasProperty misses")
  assertTrue(not hasProperty(getProperty(root, "s"), "s"), "hasProperty on a non-object is false, not a throw")
  assertTrue(isJsonInt64(getProperty(root, "n")), "3e9 fits a Long")
  assertTrue(not isJsonInt32(getProperty(root, "n")), "3e9 does not fit an Int")
  assertTrue(isJsonBool(getProperty(root, "b")), "true is a Bool")
  assertPanics("getProperty on a missing name", { -> val _ = getProperty(root, "missing") })
  assertPanics("getInt32 on an out-of-range number", { -> val _ = getInt32(getProperty(root, "n")) })
  assertPanics("getString on a number", { -> val _ = getString(getProperty(root, "n")) })
  assertPanics("getBoolean on a string", { -> val _ = getBoolean(getProperty(root, "s")) })
  disposeJson(doc)
}

func testFieldReadersFailClosed(): Unit {
  var i = 0
  assertTrue(lyricJsonGetInt("{\"a\": 7}", "a", i) and i == 7, "reads an Int field")
  assertTrue(not lyricJsonGetInt("not json", "a", i) and i == 0, "malformed body")
  assertTrue(not lyricJsonGetInt("[1, 2]", "a", i), "non-object root")
  assertTrue(not lyricJsonGetInt("{\"a\": \"7\"}", "a", i), "string where an Int is expected")
  assertTrue(not lyricJsonGetInt("{\"a\": 3000000000}", "a", i), "Int out of range")
  var l = 0i64
  assertTrue(lyricJsonGetLong("{\"a\": 3000000000}", "a", l) and l == 3000000000i64, "reads a Long field")
  assertTrue(not lyricJsonGetLong("{\"a\": true}", "a", l), "Bool where a Long is expected")
  var d = 0.0
  assertTrue(not lyricJsonGetDouble("{\"a\": null}", "a", d), "null where a Double is expected")
  var b = false
  assertTrue(not lyricJsonGetBool("\"x\"", "a", b), "string root")
  var str = ""
  assertTrue(not lyricJsonGetString("{\"a\": 1}", "a", str), "number where a String is expected")
  var sub = ""
  assertTrue(not lyricJsonGetSubObject("{", "a", sub) and sub == "{}", "truncated body")
  assertTrue(lyricJsonGetSubObject("{\"a\": {\"b\": 1}}", "a", sub) and sub.contains("\"b\""), "reads an object field")
  assertTrue(not lyricJsonGetSubObject("{\"a\": [1]}", "a", sub) and sub == "{}", "array where an object is expected")
  assertTrue(
    not lyricJsonGetSubObject("{\"a\": \"x\"}", "a", sub) and sub == "{}",
    "string where an object is expected"
  )
  assertTrue(not lyricJsonGetSubObject("{\"a\": null}", "a", sub) and sub == "{}", "null where an object is expected")
}

// A synthesised `fromJson` returns `Err` for a present field or element of
// the wrong kind, as it does for a missing one (#7401).
@generate(Json)
record Person {
  name: String
  age: Int
  initial: Char
  level: Byte
  scores: slice[Int]
}

func personErr(json: in String): Bool {
  match Person.fromJson(json) {
    case Ok(_) -> false
    case Err(_) -> true
  }
}

func testGeneratedReaderFailsClosed(): Unit {
  val good = "{\"name\": \"Ada\", \"age\": 36, \"initial\": \"A\", \"level\": 7, \"scores\": [1, 2]}"
  match Person.fromJson(good) {
    case Ok(decoded) -> {
      val p: Person = decoded
      assertTrue(
        p.name == "Ada" and p.age == 36 and p.level.toInt() == 7 and p.scores.length == 2,
        "decodes a well-formed body"
      )
    }
    case Err(e) -> assertTrue(false, "well-formed body rejected: " + e)
  }
  assertTrue(
    personErr("{\"name\": 42, \"age\": 36, \"initial\": \"A\", \"level\": 7, \"scores\": []}"),
    "number where a String is expected"
  )
  assertTrue(
    personErr("{\"name\": \"Ada\", \"age\": 3000000000, \"initial\": \"A\", \"level\": 7, \"scores\": []}"),
    "Int out of range"
  )
  assertTrue(
    personErr("{\"name\": \"Ada\", \"age\": 36, \"initial\": \"\", \"level\": 7, \"scores\": []}"),
    "empty string where a Char is expected"
  )
  assertTrue(
    personErr("{\"name\": \"Ada\", \"age\": 36, \"initial\": \"A\", \"level\": 300, \"scores\": []}"),
    "Byte out of range"
  )
  assertTrue(
    personErr("{\"name\": \"Ada\", \"age\": 36, \"initial\": \"A\", \"level\": 7, \"scores\": [1, \"x\"]}"),
    "a string element in an Int slice"
  )
}

func main(): Unit {
  testGeneratedReaderFailsClosed()
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
  testTryParseJson()
  testGetterPreconditions()
  testFieldReadersFailClosed()
  println("json_tests: ok")
}
