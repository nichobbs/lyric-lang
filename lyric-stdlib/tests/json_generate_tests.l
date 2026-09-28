//! stdlib/tests/json_generate_tests.l — `@generate(Json)` decoding (#7347).
//!
//! A synthesised `fromJson` parses its body once and decodes nested records
//! and slice elements through `fromJsonElement` from the same document. These
//! cases pin the decoded values and the exact `Err` text for every rejection
//! path. CI runs them on `--target dotnet` (in this file's own loop) and on
//! `--target jvm` (scripts/ci/json-generate-jvm-test.sh — a package with two
//! `@generate(Json)` records failed to load there until the JVM backend
//! mangled a dot-named function's classfile name with its declaring type,
//! see D-progress-1002, #7501, #7502).
package Std.Json.GenerateTests

import Std.Core
import Std.Json
import Std.Testing

@generate(Json)
record Address {
  street: String
  city: String
}

@generate(Json)
record Member {
  name: String
  age: Int
  address: Address
}

@generate(Json)
record Team {
  title: String
  lead: Member
  members: slice[Member]
  scores: slice[Int]
}

// A `@generate(Json)` record whose `fromJson` is hand-written: nested
// decodes must still run it, not a field-by-field decoder.
@generate(Json)
record Code {
  value: String
}

func Code.fromJson(json: in String): Result[Code, String] {
  match tryParseJson(json) {
    case Err(e) -> Err(e)
    case Ok(doc) -> {
      defer {
        disposeJson(doc)
      }
      val root = rootElement(doc)
      if isJsonString(root) {
        Ok(Code(value = "code:" + getString(root)))
      } else {
        Err("code must be a string")
      }
    }
  }
}

@generate(Json)
record Tagged {
  code: Code
  codes: slice[Code]
}

func teamBody(leadCity: in String): String {
  "{\"title\": \"core\", \"lead\": {\"name\": \"Ada\", \"age\": 36, \"address\": {\"street\": \"1 Main\", \"city\": " +
    leadCity +
    "}}, \"members\": [{\"name\": \"Bo\", \"age\": 30, \"address\": {\"street\": \"2 High\", \"city\": \"Oslo\"}}," +
    " {\"name\": \"Cy\", \"age\": 41, \"address\": {\"street\": \"3 Low\", \"city\": \"Rome\"}}], \"scores\": [1, 2, 3]}"
}

func teamErr(json: in String): String {
  match Team.fromJson(json) {
    case Ok(_) -> "<ok>"
    case Err(e) -> e
  }
}

func testNestedDecode(): Unit {
  match Team.fromJson(teamBody("\"Paris\"")) {
    case Ok(decoded) -> {
      val t: Team = decoded
      assertTrue(t.title == "core", "title")
      assertTrue(t.lead.name == "Ada" and t.lead.age == 36, "lead scalars")
      assertTrue(t.lead.address.city == "Paris", "lead's nested address")
      assertEqualInt(t.members.length, 2, "two members")
      assertTrue(t.members[1].name == "Cy" and t.members[1].address.city == "Rome", "second member's nested address")
      assertEqualInt(t.scores.length, 3, "three scores")
    }
    case Err(e) -> assertTrue(false, "well-formed team rejected: " + e)
  }
}

func testRoundTrip(): Unit {
  match Team.fromJson(teamBody("\"Paris\"")) {
    case Ok(decoded) -> {
      val t: Team = decoded
      match Team.fromJson(t.toJson()) {
        case Ok(again) -> {
          val u: Team = again
          assertTrue(u.lead.address.city == "Paris" and u.members[0].address.street == "2 High", "toJson round-trips")
        }
        case Err(e) -> assertTrue(false, "round-trip rejected: " + e)
      }
    }
    case Err(e) -> assertTrue(false, "well-formed team rejected: " + e)
  }
}

func testNestedRejections(): Unit {
  assertTrue(teamErr(teamBody("42")) == "field 'city': expected String", "wrong kind two levels down")
  assertTrue(
    teamErr("{\"title\": \"core\", \"lead\": {\"name\": \"Ada\", \"age\": 36}, \"members\": [], \"scores\": []}") ==
      "missing field 'address'",
    "missing field in a nested record"
  )
  assertTrue(
    teamErr("{\"title\": \"core\", \"lead\": \"Ada\", \"members\": [], \"scores\": []}") == "missing field 'name'",
    "a string where a nested record is expected"
  )
  assertTrue(
    teamErr("{\"title\": \"core\", \"lead\": [1], \"members\": [], \"scores\": []}") == "missing field 'name'",
    "an array where a nested record is expected"
  )
  assertTrue(
    teamErr("{\"title\": \"core\", \"lead\": null, \"members\": [], \"scores\": []}") == "missing field 'name'",
    "null where a nested record is expected"
  )
  val goodLead = "{\"name\": \"Ada\", \"age\": 36, \"address\": {\"street\": \"1 Main\", \"city\": \"Paris\"}}"
  assertTrue(
    teamErr("{\"title\": \"core\", \"lead\": " + goodLead + ", \"members\": [7], \"scores\": []}") ==
      "missing field 'name'",
    "a number element in a slice of records"
  )
  assertTrue(
    teamErr("{\"title\": \"core\", \"lead\": " + goodLead + ", \"members\": [], \"scores\": [1, true]}") ==
      "an element of field 'scores': expected Int",
    "a Bool element in an Int slice"
  )
  assertTrue(
    teamErr("{\"title\": \"core\", \"lead\": " + goodLead + ", \"members\": []}") == "missing field 'scores'",
    "missing top-level field"
  )
}

func testMalformedAndNonObjectBodies(): Unit {
  assertTrue(teamErr("{\"title\": ") != "<ok>", "truncated body")
  assertTrue(teamErr("not json") != "<ok>", "malformed body")
  assertTrue(teamErr("") != "<ok>", "empty body")
  assertTrue(teamErr("[1, 2]") == "missing field 'title'", "array root")
  assertTrue(teamErr("\"team\"") == "missing field 'title'", "string root")
  assertTrue(teamErr("null") == "missing field 'title'", "null root")
}

func testFromJsonElement(): Unit {
  val doc = parseJson("{\"street\": \"9 Elm\", \"city\": \"Lima\"}")
  defer {
    disposeJson(doc)
  }
  match Address.fromJsonElement(rootElement(doc)) {
    case Ok(decoded) -> {
      val a: Address = decoded
      assertTrue(a.street == "9 Elm" and a.city == "Lima", "decodes from an element the caller owns")
    }
    case Err(e) -> assertTrue(false, "fromJsonElement rejected: " + e)
  }
}

func testHandWrittenNestedDecoder(): Unit {
  match Tagged.fromJson("{\"code\": \"x\", \"codes\": [\"y\", \"z\"]}") {
    case Ok(decoded) -> {
      val t: Tagged = decoded
      assertTrue(t.code.value == "code:x", "nested field runs the hand-written fromJson")
      assertTrue(t.codes.length == 2 and t.codes[1].value == "code:z", "slice elements run the hand-written fromJson")
    }
    case Err(e) -> assertTrue(false, "Tagged rejected: " + e)
  }
  match Tagged.fromJson("{\"code\": 1, \"codes\": []}") {
    case Ok(_) -> assertTrue(false, "a number code was accepted")
    case Err(e) -> assertTrue(e == "code must be a string", "the hand-written decoder's Err propagates")
  }
}

func main(): Unit {
  testNestedDecode()
  testRoundTrip()
  testNestedRejections()
  testMalformedAndNonObjectBodies()
  testFromJsonElement()
  testHandWrittenNestedDecoder()
  println("json_generate_tests: ok")
}
