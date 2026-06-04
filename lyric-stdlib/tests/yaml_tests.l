//! stdlib/tests/yaml_tests.l — Tests for Std.Yaml.
//!
//! Covers: JSON strict mode (null, bool, int, string, array, object,
//! nesting, escape sequences, empty collections), YAML mode (scalars,
//! bool aliases, null aliases, single-quoted strings, flow collections,
//! block mappings, block sequences), query helpers, and error cases.
package Std.Yaml.Tests

import Std.Core
import Std.Collections
import Std.Yaml
import Std.Testing

// ── JSON mode ──────────────────────────────────────────────────────────────────
func testJsonNull(): Unit {
  match parseJson("null") {
    case Err(e) -> assertTrue(false, "json null: " + YamlError.message(e))
    case Ok(v) -> assertTrue(isNull(v), "json null")
  }
}

func testJsonBool(): Unit {
  match parseJson("true") {
    case Err(e) -> assertTrue(false, "json true: " + YamlError.message(e))
    case Ok(v) -> {
      match asBool(v) {
        case Some(b) -> assertTrue(b, "json true value")
        case None -> assertTrue(false, "json true: not bool")
      }
    }
  }
  match parseJson("false") {
    case Err(e) -> assertTrue(false, "json false: " + YamlError.message(e))
    case Ok(v) -> {
      match asBool(v) {
        case Some(b) -> assertTrue(not b, "json false value")
        case None -> assertTrue(false, "json false: not bool")
      }
    }
  }
}

func testJsonInt(): Unit {
  match parseJson("42") {
    case Err(e) -> assertTrue(false, "json 42: " + YamlError.message(e))
    case Ok(v) -> {
      match asInt(v) {
        case Some(n) -> assertTrue(n == 42i64, "json 42 value")
        case None -> assertTrue(false, "json 42: not int")
      }
    }
  }
  match parseJson("-999") {
    case Err(e) -> assertTrue(false, "json -999: " + YamlError.message(e))
    case Ok(v) -> {
      match asInt(v) {
        case Some(n) -> assertTrue(n == -999i64, "json -999 value")
        case None -> assertTrue(false, "json -999: not int")
      }
    }
  }
  match parseJson("0") {
    case Err(e) -> assertTrue(false, "json 0: " + YamlError.message(e))
    case Ok(v) -> {
      match asInt(v) {
        case Some(n) -> assertTrue(n == 0i64, "json 0 value")
        case None -> assertTrue(false, "json 0: not int")
      }
    }
  }
}

func testJsonString(): Unit {
  match parseJson("\"hello\"") {
    case Err(e) -> assertTrue(false, "json str: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "hello", "json string value")
        case None -> assertTrue(false, "json str: not string")
      }
    }
  }
  match parseJson("\"\"") {
    case Err(e) -> assertTrue(false, "json empty str: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "", "json empty string")
        case None -> assertTrue(false, "json empty str: not string")
      }
    }
  }
}

func testJsonEscapes(): Unit {
  match parseJson("\"line1\\nline2\"") {
    case Err(e) -> assertTrue(false, "json esc nl: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s.contains("\n"), "json newline escape")
        case None -> assertTrue(false, "esc nl: not string")
      }
    }
  }
  match parseJson("\"tab\\there\"") {
    case Err(e) -> assertTrue(false, "json esc tab: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s.contains("\t"), "json tab escape")
        case None -> assertTrue(false, "esc tab: not string")
      }
    }
  }
  match parseJson("\"quote\\\"end\"") {
    case Err(e) -> assertTrue(false, "json esc quote: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s.contains("\""), "json quote escape")
        case None -> assertTrue(false, "esc quote: not string")
      }
    }
  }
}

func testJsonArray(): Unit {
  match parseJson("[1, 2, 3]") {
    case Err(e) -> assertTrue(false, "json array: " + YamlError.message(e))
    case Ok(v) -> {
      match asSequence(v) {
        case None -> assertTrue(false, "json array: not sequence")
        case Some(xs) -> {
          assertEqualInt(xs.count, 3, "json array length")
          match asInt(xs[0]) {
            case Some(n) -> assertTrue(n == 1i64, "json array[0]")
            case None -> assertTrue(false, "array[0] not int")
          }
          match asInt(xs[2]) {
            case Some(n) -> assertTrue(n == 3i64, "json array[2]")
            case None -> assertTrue(false, "array[2] not int")
          }
        }
      }
    }
  }
  match parseJson("[]") {
    case Err(e) -> assertTrue(false, "json empty array: " + YamlError.message(e))
    case Ok(v) -> {
      match asSequence(v) {
        case None -> assertTrue(false, "empty array: not sequence")
        case Some(xs) -> assertEqualInt(xs.count, 0, "empty array length")
      }
    }
  }
}

func testJsonObject(): Unit {
  match parseJson("{\"a\":1,\"b\":\"hello\",\"c\":true}") {
    case Err(e) -> assertTrue(false, "json obj: " + YamlError.message(e))
    case Ok(v) -> {
      match getInt(v, "a") {
        case Some(n) -> assertTrue(n == 1i64, "obj a=1")
        case None -> assertTrue(false, "obj a missing")
      }
      match getString(v, "b") {
        case Some(s) -> assertTrue(s == "hello", "obj b=hello")
        case None -> assertTrue(false, "obj b missing")
      }
      match getBool(v, "c") {
        case Some(b) -> assertTrue(b, "obj c=true")
        case None -> assertTrue(false, "obj c missing")
      }
    }
  }
  match parseJson("{}") {
    case Err(e) -> assertTrue(false, "json empty obj: " + YamlError.message(e))
    case Ok(v) -> {
      match asMapping(v) {
        case None -> assertTrue(false, "empty obj: not mapping")
        case Some(ps) -> assertEqualInt(ps.count, 0, "empty obj length")
      }
    }
  }
}

func testJsonNested(): Unit {
  match parseJson("{\"items\":[1,2],\"meta\":{\"count\":2}}") {
    case Err(e) -> assertTrue(false, "json nested: " + YamlError.message(e))
    case Ok(v) -> {
      match getField(v, "items") {
        case None -> assertTrue(false, "items missing")
        case Some(f) -> {
          match asSequence(f) {
            case None -> assertTrue(false, "items not sequence")
            case Some(xs) -> assertEqualInt(xs.count, 2, "items length")
          }
        }
      }
      match getField(v, "meta") {
        case None -> assertTrue(false, "meta missing")
        case Some(m) -> {
          match getInt(m, "count") {
            case Some(n) -> assertTrue(n == 2i64, "meta.count")
            case None -> assertTrue(false, "meta.count missing")
          }
        }
      }
    }
  }
}

// ── YAML mode ──────────────────────────────────────────────────────────────────
func testYamlNull(): Unit {
  match parseYaml("~") {
    case Err(e) -> assertTrue(false, "yaml ~: " + YamlError.message(e))
    case Ok(v) -> assertTrue(isNull(v), "yaml ~ is null")
  }
  match parseYaml("null") {
    case Err(e) -> assertTrue(false, "yaml null: " + YamlError.message(e))
    case Ok(v) -> assertTrue(isNull(v), "yaml null keyword")
  }
}

// YAML 1.2 §10.3.2: only `true`/`false` (and their case variants) are
// booleans.  The YAML 1.1 aliases `yes/no/on/off` are plain strings.
func testYamlBoolAliases(): Unit {
  match parseYaml("true") {
    case Err(e) -> assertTrue(false, "yaml true: " + YamlError.message(e))
    case Ok(v) -> {
      match asBool(v) {
        case Some(b) -> assertTrue(b, "true")
        case None -> assertTrue(false, "not bool")
      }
    }
  }
  match parseYaml("false") {
    case Err(e) -> assertTrue(false, "yaml false: " + YamlError.message(e))
    case Ok(v) -> {
      match asBool(v) {
        case Some(b) -> assertTrue(not b, "false")
        case None -> assertTrue(false, "not bool")
      }
    }
  }
  // YAML 1.1 aliases must parse as strings in YAML 1.2 mode.
  match parseYaml("yes") {
    case Err(e) -> assertTrue(false, "yaml yes err: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "yes", "yes=string")
        case None -> assertTrue(false, "yes not string")
      }
    }
  }
  match parseYaml("no") {
    case Err(e) -> assertTrue(false, "yaml no err: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "no", "no=string")
        case None -> assertTrue(false, "no not string")
      }
    }
  }
  match parseYaml("on") {
    case Err(e) -> assertTrue(false, "yaml on err: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "on", "on=string")
        case None -> assertTrue(false, "on not string")
      }
    }
  }
  match parseYaml("off") {
    case Err(e) -> assertTrue(false, "yaml off err: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "off", "off=string")
        case None -> assertTrue(false, "off not string")
      }
    }
  }
}

func testYamlInt(): Unit {
  match parseYaml("42") {
    case Err(e) -> assertTrue(false, "yaml int: " + YamlError.message(e))
    case Ok(v) -> {
      match asInt(v) {
        case Some(n) -> assertTrue(n == 42i64, "yaml 42")
        case None -> assertTrue(false, "not int")
      }
    }
  }
  match parseYaml("-7") {
    case Err(e) -> assertTrue(false, "yaml -7: " + YamlError.message(e))
    case Ok(v) -> {
      match asInt(v) {
        case Some(n) -> assertTrue(n == -7i64, "yaml -7")
        case None -> assertTrue(false, "not int")
      }
    }
  }
}

func testYamlSingleQuoted(): Unit {
  match parseYaml("'hello world'") {
    case Err(e) -> assertTrue(false, "yaml sq: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "hello world", "sq string")
        case None -> assertTrue(false, "not string")
      }
    }
  }
  match parseYaml("'it''s alive'") {
    case Err(e) -> assertTrue(false, "yaml sq escape: " + YamlError.message(e))
    case Ok(v) -> {
      match asString(v) {
        case Some(s) -> assertTrue(s == "it's alive", "sq escape ''")
        case None -> assertTrue(false, "not string")
      }
    }
  }
}

func testYamlFlowArray(): Unit {
  match parseYaml("[1, 2, 3]") {
    case Err(e) -> assertTrue(false, "yaml flow arr: " + YamlError.message(e))
    case Ok(v) -> {
      match asSequence(v) {
        case None -> assertTrue(false, "flow array: not sequence")
        case Some(xs) -> assertEqualInt(xs.count, 3, "yaml flow array length")
      }
    }
  }
}

func testYamlFlowMapping(): Unit {
  match parseYaml("{name: Alice, age: 30}") {
    case Err(e) -> assertTrue(false, "yaml flow map: " + YamlError.message(e))
    case Ok(v) -> {
      match getString(v, "name") {
        case Some(s) -> assertTrue(s == "Alice", "flow map name")
        case None -> assertTrue(false, "flow map name missing")
      }
    }
  }
}

func testYamlBlockMapping(): Unit {
  match parseYaml("name: Alice\nage: 30\nactive: true\n") {
    case Err(e) -> assertTrue(false, "yaml block map: " + YamlError.message(e))
    case Ok(v) -> {
      match getString(v, "name") {
        case Some(s) -> assertTrue(s == "Alice", "block map name")
        case None -> assertTrue(false, "block map name missing")
      }
      match getBool(v, "active") {
        case Some(b) -> assertTrue(b, "block map active")
        case None -> assertTrue(false, "block map active missing")
      }
    }
  }
}

func testYamlBlockSequence(): Unit {
  match parseYaml("- one\n- two\n- three\n") {
    case Err(e) -> assertTrue(false, "yaml block seq: " + YamlError.message(e))
    case Ok(v) -> {
      match asSequence(v) {
        case None -> assertTrue(false, "block seq: not sequence")
        case Some(xs) -> {
          assertEqualInt(xs.count, 3, "block seq length")
          match asString(xs[0]) {
            case Some(s) -> assertTrue(s == "one", "block seq[0]")
            case None -> assertTrue(false, "block seq[0] not string")
          }
        }
      }
    }
  }
}

func testJsonErrorUnexpectedEof(): Unit {
  match parseJson("{\"a\":") {
    case Err(e) -> assertTrue(YamlError.message(e).length > 0, "eof error has message")
    case Ok(_) -> assertTrue(false, "truncated JSON should fail")
  }
}

func testJsonErrorTrailing(): Unit {
  match parseJson("42 extra") {
    case Err(e) -> assertTrue(YamlError.message(e).length > 0, "trailing garbage error")
    case Ok(_) -> assertTrue(false, "trailing garbage should fail")
  }
}

func testGetFieldMissing(): Unit {
  match parseJson("{\"x\":1}") {
    case Err(e) -> assertTrue(false, "getField setup: " + YamlError.message(e))
    case Ok(v) -> assertTrue(isNone(getField(v, "y")), "missing field is None")
  }
}

// ── Float parsing (#581) ───────────────────────────────────────────────────────
func testYamlFloatBlock(): Unit {
  match parseYaml("1.5") {
    case Err(e) -> assertTrue(false, "float block: " + YamlError.message(e))
    case Ok(v) -> match asFloat(v) { case None -> assertTrue(false, "expected YFloat"); case Some(f) -> assertTrue(f == 1.5, "block scalar 1.5 parsed as YFloat") }
  }
}

func testJsonFloatRoundtrip(): Unit {
  match parseJson("{\"x\":3.14}") {
    case Err(e) -> assertTrue(false, "json float: " + YamlError.message(e))
    case Ok(v) -> match getFloat(v, "x") { case None -> assertTrue(false, "getFloat should return Some"); case Some(f) -> assertTrue(f == 3.14, "getFloat returns 3.14") }
  }
}

func testAsFloatNonFloat(): Unit {
  match parseJson("42") {
    case Err(e) -> assertTrue(false, "asFloat setup: " + YamlError.message(e))
    case Ok(v) -> assertTrue(isNone(asFloat(v)), "asFloat on int returns None")
  }
}

func testYamlFloatExponent(): Unit {
  match parseYaml("1.0e2") {
    case Err(e) -> assertTrue(false, "float exp: " + YamlError.message(e))
    case Ok(v) -> match asFloat(v) { case None -> assertTrue(false, "1.0e2 should be YFloat"); case Some(f) -> assertTrue(f == 100.0, "1.0e2 == 100.0") }
  }
}

// ── DuplicateKey errors (#582) ─────────────────────────────────────────────────
func testJsonDuplicateKey(): Unit {
  match parseJson("{\"a\":1,\"a\":2}") {
    case Err(e) -> assertTrue(YamlError.message(e).length > 0, "duplicate key error should have message")
    case Ok(_) -> assertTrue(false, "duplicate key must be rejected")
  }
}

func testYamlFlowDuplicateKey(): Unit {
  match parseYaml("{a: 1, a: 2}") {
    case Err(e) -> assertTrue(YamlError.message(e).length > 0, "flow duplicate key error")
    case Ok(_) -> assertTrue(false, "flow duplicate key must be rejected")
  }
}

func testYamlBlockDuplicateKey(): Unit {
  match parseYaml("a: 1\na: 2") {
    case Err(e) -> assertTrue(YamlError.message(e).length > 0, "block duplicate key error")
    case Ok(_) -> assertTrue(false, "block duplicate key must be rejected")
  }
}

// ── Depth guard (#583) ─────────────────────────────────────────────────────────
func testYamlDepthGuard(): Unit {
  // 2000 nested flow arrays must be rejected by the depth guard.
  var s = "x"
  var d = 0
  while d < 2000 {
    s = "[" + s + "]"
    d = d + 1
  }
  match parseYaml(s) {
    case Err(e) -> assertTrue(YamlError.message(e).length > 0, "depth guard fires on 2000-deep document")
    case Ok(_) -> assertTrue(false, "2000-deep document must be rejected")
  }
}

func testYamlDepthBoundary(): Unit {
  // A shallow document (100 levels) is well within the depth limit.
  var s = "x"
  var d = 0
  while d < 100 {
    s = "[" + s + "]"
    d = d + 1
  }
  match parseYaml(s) {
    case Err(e) -> assertTrue(false, "100-deep document should parse: " + YamlError.message(e))
    case Ok(_) -> assertTrue(true, "100-deep document parsed ok")
  }
}

func main(): Unit {
  testJsonNull()
  testJsonBool()
  testJsonInt()
  testJsonString()
  testJsonEscapes()
  testJsonArray()
  testJsonObject()
  testJsonNested()
  testYamlNull()
  testYamlBoolAliases()
  testYamlInt()
  testYamlSingleQuoted()
  testYamlFlowArray()
  testYamlFlowMapping()
  testYamlBlockMapping()
  testYamlBlockSequence()
  testJsonErrorUnexpectedEof()
  testJsonErrorTrailing()
  testGetFieldMissing()
  testYamlFloatBlock()
  testJsonFloatRoundtrip()
  testAsFloatNonFloat()
  testYamlFloatExponent()
  testJsonDuplicateKey()
  testYamlFlowDuplicateKey()
  testYamlBlockDuplicateKey()
  testYamlDepthGuard()
  testYamlDepthBoundary()
  println("yaml_tests: ok")
}
