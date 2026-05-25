// contract_meta_self_test.l — exercises the in-process JSON parser
// in `Lyric.ContractMeta.parseFromJson` (#1229 Phase A.1) and the
// in-process resource readers `readFromFile` /
// `readAllContractsFromFile` (#1229 Phase A.3).
//
// Compiled and executed by SelfHostedContractMetaTests.fs.  Exit 0 +
// "ok" in stdout means every assertion held.

package Lyric.ContractMeta.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
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

// Non-object entries inside the `decls` array are silently skipped
// (matches F# — the parser only yields objects).  Pins the defensive
// skip path so future schema additions don't crash the parser.
func testNonObjectDeclEntrySkipped(): Unit {
  val json =
    "{\"decls\":[" +
    "  {\"kind\":\"func\",\"name\":\"keep\"}," +
    "  \"a-string-not-an-object\"," +
    "  42," +
    "  null," +
    "  {\"kind\":\"func\",\"name\":\"alsoKeep\"}" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "non_object_decl_entry_skipped")
  assertEqualInt(c.decls.count, 2, "non_object_decl_entry_skipped: only object entries kept")
  assertEqual(c.decls[0].name, "keep", "non_object_decl_entry_skipped: first kept")
  assertEqual(c.decls[1].name, "alsoKeep", "non_object_decl_entry_skipped: second kept")
}

// `decls` field present but not an Array → silently treated as absent
// (returns a Contract with empty decls).
func testNonArrayDeclsFieldSkipped(): Unit {
  val json = "{\"packageName\":\"P\",\"decls\":\"not-an-array\"}"
  val c = unwrapOrFail(parseFromJson(json), "non_array_decls_field_skipped")
  assertEqual(c.packageName, "P", "non_array_decls_field_skipped: other fields parsed")
  assertEqualInt(c.decls.count, 0, "non_array_decls_field_skipped: decls empty")
}

// Non-object entries inside `params` array are silently skipped.  Same
// defensive shape as the decls-array skip.
func testNonObjectParamEntrySkipped(): Unit {
  val json =
    "{\"decls\":[" +
    "  {" +
    "    \"name\":\"f\"," +
    "    \"params\":[" +
    "      {\"name\":\"a\",\"type\":\"Int\"}," +
    "      \"not-an-object\"," +
    "      null," +
    "      {\"name\":\"b\",\"type\":\"String\"}" +
    "    ]" +
    "  }" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "non_object_param_entry_skipped")
  assertEqualInt(c.decls[0].params.count, 2,
    "non_object_param_entry_skipped: only objects kept")
  assertEqual(c.decls[0].params[0].name, "a", "non_object_param_entry_skipped: p0")
  assertEqual(c.decls[0].params[1].name, "b", "non_object_param_entry_skipped: p1")
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. In-process resource readers (#1229 Phase A.3)
// ─────────────────────────────────────────────────────────────────────────────
//
// The auto-discovery runner (`SelfHostedContractMetaTests.fs`) emits
// this program as `self_hosted_contract_meta.dll`.  Every Lyric-
// emitted assembly has an embedded `Lyric.Contract` resource (the
// emitter writes it during `emit`), so we can verify the in-process
// reader against the running test PE itself.

func selfDllPath(): String {
  Path.join(Environment.appBaseDirectory(), "self_hosted_contract_meta.dll")
}

// `readFromFile` reads the embedded JSON in-process via
// `Std.AssemblyResources` (no subprocess).  The bytes must round-trip
// through `parseFromJson` cleanly — pinning the read + parse pipeline
// the bridge's restored-dep loader uses.
func testReadFromFileInProcess(): Unit {
  match readFromFile(selfDllPath()) {
    case None -> panic("read_from_file_in_process: expected Some(json)")
    case Some(json) -> {
      assertTrue(Str.isNotEmpty(json),
        "read_from_file_in_process: json non-empty")
      // Round-trip through the parser to confirm the JSON shape.
      val c = unwrapOrFail(parseFromJson(json), "read_from_file_in_process")
      assertTrue(Str.isNotEmpty(c.packageName),
        "read_from_file_in_process: packageName present")
    }
  }
}

// `readFromFile` against a non-existent path throws — the test PE
// itself always exists, so we only assert the positive case here.
// (`readFromFile` is throw-on-missing-file by design; the bridge
// pre-checks via `Std.File.exists` before calling.)

// `readAllContractsFromFile` surfaces at least one entry for a
// single-package Lyric assembly (the `Lyric.Contract` legacy form).
// The pkgName for legacy resources is "" (empty) per the F# parity
// contract.
func testReadAllContractsFromFileSinglePkg(): Unit {
  val entries = readAllContractsFromFile(selfDllPath())
  assertTrue(entries.count >= 1,
    "read_all_single_pkg: at least one entry")
  // Find the legacy entry.
  var foundLegacy = false
  var i = 0
  while i < entries.count {
    if entries[i].packageName == "" and Str.isNotEmpty(entries[i].json) {
      foundLegacy = true
    }
    i = i + 1
  }
  assertTrue(foundLegacy,
    "read_all_single_pkg: legacy (`Lyric.Contract`, packageName = \"\") entry present")
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Driver
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
  testNonObjectDeclEntrySkipped()
  testNonArrayDeclsFieldSkipped()
  testReadFromFileInProcess()
  testReadAllContractsFromFileSinglePkg()
  testNonObjectParamEntrySkipped()
  println("contract-meta self-test: ok")
  return 0
}
