// contract_meta_self_test.l — exercises the in-process JSON parser
// in `Lyric.ContractMeta.parseFromJson` (#1229 Phase A).
//
// Compiled and executed by SelfHostedContractMetaTests.fs.  Exit 0 +
// "ok" in stdout means every assertion held.

package Lyric.ContractMeta.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.ContractMeta

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────

func unwrapOrFail(opt: in Option[Contract], label: in String): Contract {
  match opt {
    case Some(c) -> c
    case None    -> {
      panic(label + ": parseFromJson returned None on valid input")
      // unreachable
      Contract(packageName = "", version = "", level = "", formatVersion = 0,
               decls = newList())
    }
  }
}

func findDecl(decls: in List[ContractDecl], name: in String): Option[ContractDecl] {
  var i = 0
  while i < decls.count {
    if decls[i].name == name { return Some(value = decls[i]) }
    i = i + 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Tests
// ─────────────────────────────────────────────────────────────────────────────

// Minimal valid contract: packageName + version + a single decl.
func testMinimal(): Unit {
  val json =
    "{" +
    "\"formatVersion\":2," +
    "\"packageName\":\"My.Pkg\"," +
    "\"version\":\"1.2.3\"," +
    "\"level\":\"runtime_checked\"," +
    "\"decls\":[" +
    "  {\"kind\":\"func\",\"name\":\"double\",\"repr\":\"func double(x: Int): Int\"}" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "minimal")
  assertEqual(c.packageName, "My.Pkg", "minimal: packageName")
  assertEqual(c.version, "1.2.3", "minimal: version")
  assertEqual(c.level, "runtime_checked", "minimal: level")
  assertEqualInt(c.formatVersion, 2, "minimal: formatVersion")
  assertEqualInt(c.decls.count, 1, "minimal: one decl")
  assertEqual(c.decls[0].kind, "func", "minimal: decl kind")
  assertEqual(c.decls[0].name, "double", "minimal: decl name")
  assertEqual(c.decls[0].repr, "func double(x: Int): Int", "minimal: decl repr")
}

// Field defaults: empty JSON object → defaults match F# parser.
func testEmptyObjectDefaults(): Unit {
  val c = unwrapOrFail(parseFromJson("{}"), "empty_object_defaults")
  assertEqual(c.packageName, "", "empty: packageName default")
  assertEqual(c.version, "0.0.0", "empty: version default")
  assertEqual(c.level, "runtime_checked", "empty: level default")
  assertEqualInt(c.formatVersion, 1, "empty: formatVersion default (format-1 fallback)")
  assertEqualInt(c.decls.count, 0, "empty: no decls")
}

// Empty string or whitespace input → None.
func testEmptyStringReturnsNone(): Unit {
  match parseFromJson("") {
    case None    -> ()
    case Some(_) -> panic("empty_string: expected None")
  }
  match parseFromJson("   \n  ") {
    case None    -> ()
    case Some(_) -> panic("whitespace_string: expected None")
  }
}

// Non-object root JSON → None (e.g. an array literal isn't a Contract).
func testNonObjectRootReturnsNone(): Unit {
  match parseFromJson("[1, 2, 3]") {
    case None    -> ()
    case Some(_) -> panic("array_root: expected None")
  }
}

// Syntactically invalid JSON → None (parser would otherwise panic with
// a Bug from System.Text.Json).
func testMalformedJsonReturnsNone(): Unit {
  match parseFromJson("{not valid json") {
    case None    -> ()
    case Some(_) -> panic("malformed_json: expected None")
  }
  match parseFromJson("{\"unterminated\":") {
    case None    -> ()
    case Some(_) -> panic("malformed_json: unterminated value expected None")
  }
  match parseFromJson("garbage tokens here") {
    case None    -> ()
    case Some(_) -> panic("malformed_json: garbage expected None")
  }
}

// `pure: true` and `requires`/`ensures` arrays parse correctly.
func testPureAndContracts(): Unit {
  val json =
    "{" +
    "\"packageName\":\"Math\"," +
    "\"decls\":[" +
    "  {" +
    "    \"kind\":\"func\"," +
    "    \"name\":\"abs\"," +
    "    \"repr\":\"func abs(x: Int): Int\"," +
    "    \"pure\":true," +
    "    \"requires\":[\"x != minInt\"]," +
    "    \"ensures\":[\"result >= 0\",\"result == abs_math(x)\"]" +
    "  }" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "pure_and_contracts")
  val d = findDecl(c.decls, "abs")
  match d {
    case None -> panic("pure_and_contracts: decl abs not found")
    case Some(decl) -> {
      assertTrue(decl.isPure, "pure_and_contracts: pure=true")
      assertEqualInt(decl.requiresClauses.count, 1, "pure_and_contracts: one require")
      assertEqual(decl.requiresClauses[0], "x != minInt", "pure_and_contracts: require text")
      assertEqualInt(decl.ensuresClauses.count, 2, "pure_and_contracts: two ensures")
      assertEqual(decl.ensuresClauses[0], "result >= 0", "pure_and_contracts: ensures[0]")
      assertEqual(decl.ensuresClauses[1], "result == abs_math(x)", "pure_and_contracts: ensures[1]")
    }
  }
}

// `body` field present → Option[String] = Some(text); absent → None.
func testBodyOptional(): Unit {
  val withBody =
    "{\"decls\":[{\"kind\":\"func\",\"name\":\"id\",\"body\":\"x\"}]}"
  val c1 = unwrapOrFail(parseFromJson(withBody), "body_present")
  match c1.decls[0].body {
    case Some(s) -> assertEqual(s, "x", "body_present: body text")
    case None    -> panic("body_present: expected Some")
  }
  val noBody =
    "{\"decls\":[{\"kind\":\"func\",\"name\":\"id\"}]}"
  val c2 = unwrapOrFail(parseFromJson(noBody), "body_absent")
  match c2.decls[0].body {
    case None    -> ()
    case Some(_) -> panic("body_absent: expected None")
  }
}

// `params` array parses (name, type) tuples.
func testParamsArray(): Unit {
  val json =
    "{\"decls\":[" +
    "  {" +
    "    \"kind\":\"func\"," +
    "    \"name\":\"add\"," +
    "    \"params\":[" +
    "      {\"name\":\"a\",\"type\":\"Int\"}," +
    "      {\"name\":\"b\",\"type\":\"Int\"}" +
    "    ]" +
    "  }" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "params_array")
  val d = c.decls[0]
  assertEqualInt(d.params.count, 2, "params_array: two params")
  assertEqual(d.params[0].name, "a", "params_array: p0.name")
  assertEqual(d.params[0].ty, "Int", "params_array: p0.type")
  assertEqual(d.params[1].name, "b", "params_array: p1.name")
  assertEqual(d.params[1].ty, "Int", "params_array: p1.type")
}

// Stability field round-trips: "stable:X.Y" / "experimental" / "".
func testStability(): Unit {
  val json =
    "{\"decls\":[" +
    "  {\"name\":\"a\",\"stability\":\"stable:1.0\"}," +
    "  {\"name\":\"b\",\"stability\":\"experimental\"}," +
    "  {\"name\":\"c\"}" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "stability")
  assertEqual(c.decls[0].stability, "stable:1.0", "stability: explicit")
  assertEqual(c.decls[1].stability, "experimental", "stability: experimental")
  assertEqual(c.decls[2].stability, "", "stability: absent default empty")
}

// Multiple decls in `decls` array preserve order.
func testMultipleDeclsOrder(): Unit {
  val json =
    "{\"decls\":[" +
    "  {\"kind\":\"record\",\"name\":\"Point\"}," +
    "  {\"kind\":\"func\",\"name\":\"makePoint\"}," +
    "  {\"kind\":\"union\",\"name\":\"Maybe\"}" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "multiple_decls")
  assertEqualInt(c.decls.count, 3, "multiple_decls: three decls")
  assertEqual(c.decls[0].name, "Point", "multiple_decls: order [0]")
  assertEqual(c.decls[1].name, "makePoint", "multiple_decls: order [1]")
  assertEqual(c.decls[2].name, "Maybe", "multiple_decls: order [2]")
}

// `pure` absent → defaults to false (matches F# parser).
func testPureDefaultsFalse(): Unit {
  val json = "{\"decls\":[{\"name\":\"a\"}]}"
  val c = unwrapOrFail(parseFromJson(json), "pure_default")
  assertTrue(not c.decls[0].isPure, "pure_default: false when absent")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Driver
// ─────────────────────────────────────────────────────────────────────────────

func main(): Int {
  testMinimal()
  testEmptyObjectDefaults()
  testEmptyStringReturnsNone()
  testNonObjectRootReturnsNone()
  testMalformedJsonReturnsNone()
  testPureAndContracts()
  testBodyOptional()
  testParamsArray()
  testStability()
  testMultipleDeclsOrder()
  testPureDefaultsFalse()
  println("contract-meta self-test: ok")
  return 0
}
