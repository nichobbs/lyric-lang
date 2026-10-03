//! contract_meta_self_test.l — exercises the in-process JSON parser
//! in `Lyric.ContractMeta.parseFromJson` (#1229 Phase A.1) and the
//! in-process resource readers `readFromFile` /
//! `readAllContractsFromFile` (#1229 Phase A.3).
//!
//! Run via `lyric test lyric-compiler/lyric/contract_meta_self_test.l`.
//! Replaces the F# SelfHostedContractMetaTests.fs wrapper (#2580).
@test_module
package Lyric.ContractMeta.SelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Lyric.ContractMeta
import Lyric.ContractElaborator
import Lyric.Parser

// ─────────────────────────────────────────────────────────────────────────────
// §1. Helpers
// ─────────────────────────────────────────────────────────────────────────────
func unwrapOrFail(opt: in Option[Contract], label: in String): Contract {
  match opt {
    case Some(c) -> c
    case None -> {
      panic(label + ": parseFromJson returned None on valid input")
      // unreachable
      Contract(
        packageName = "",
        version = "",
        level = "",
        purity = "",
        formatVersion = 0,
        decls = newList(),
        dependencies = newList(),
        imports = newList(),
        wholeImports = newList(),
        selectedImports = newList(),
        contractHash = ""
      )
    }
  }
}

func findDecl(decls: in List[ContractDecl], name: in String): Option[ContractDecl] {
  var i = 0
  while i < decls.count {
    if decls[i].name == name {
      return Some(value = decls[i])
    }
    i = i + 1
  }
  None
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Tests
// ─────────────────────────────────────────────────────────────────────────────
// Minimal valid contract: packageName + version + a single decl.
func testMinimal(): Unit {
  val json = "{" + "\"formatVersion\":2," + "\"packageName\":\"My.Pkg\"," + "\"version\":\"1.2.3\"," +
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
    case None -> ()
    case Some(_) -> panic("empty_string: expected None")
  }
  match parseFromJson("   \n  ") {
    case None -> ()
    case Some(_) -> panic("whitespace_string: expected None")
  }
}

// Non-object root JSON → None (e.g. an array literal isn't a Contract).
func testNonObjectRootReturnsNone(): Unit {
  match parseFromJson("[1, 2, 3]") {
    case None -> ()
    case Some(_) -> panic("array_root: expected None")
  }
}

// Syntactically invalid JSON → None (parser would otherwise panic with
// a Bug from System.Text.Json).
func testMalformedJsonReturnsNone(): Unit {
  match parseFromJson("{not valid json") {
    case None -> ()
    case Some(_) -> panic("malformed_json: expected None")
  }
  match parseFromJson("{\"unterminated\":") {
    case None -> ()
    case Some(_) -> panic("malformed_json: unterminated value expected None")
  }
  match parseFromJson("garbage tokens here") {
    case None -> ()
    case Some(_) -> panic("malformed_json: garbage expected None")
  }
}

// `pure: true` and `requires`/`ensures` arrays parse correctly.
func testPureAndContracts(): Unit {
  val json = "{" + "\"packageName\":\"Math\"," + "\"decls\":[" + "  {" + "    \"kind\":\"func\"," +
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
  val withBody = "{\"decls\":[{\"kind\":\"func\",\"name\":\"id\",\"body\":\"x\"}]}"
  val c1 = unwrapOrFail(parseFromJson(withBody), "body_present")
  match c1.decls[0].body {
    case Some(s) -> assertEqual(s, "x", "body_present: body text")
    case None -> panic("body_present: expected Some")
  }
  val noBody = "{\"decls\":[{\"kind\":\"func\",\"name\":\"id\"}]}"
  val c2 = unwrapOrFail(parseFromJson(noBody), "body_absent")
  match c2.decls[0].body {
    case None -> ()
    case Some(_) -> panic("body_absent: expected None")
  }
}

// `params` array parses (name, type) tuples.
func testParamsArray(): Unit {
  val json = "{\"decls\":[" + "  {" + "    \"kind\":\"func\"," + "    \"name\":\"add\"," + "    \"params\":[" +
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
  val json = "{\"decls\":[" + "  {\"name\":\"a\",\"stability\":\"stable:1.0\"}," +
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
  val json = "{\"decls\":[" + "  {\"kind\":\"record\",\"name\":\"Point\"}," +
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
  val json = "{\"decls\":[" + "  {\"kind\":\"func\",\"name\":\"keep\"}," + "  \"a-string-not-an-object\"," + "  42," +
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
  val json = "{\"decls\":[" + "  {" + "    \"name\":\"f\"," + "    \"params\":[" +
    "      {\"name\":\"a\",\"type\":\"Int\"}," +
    "      \"not-an-object\"," +
    "      null," +
    "      {\"name\":\"b\",\"type\":\"String\"}" +
    "    ]" +
    "  }" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "non_object_param_entry_skipped")
  assertEqualInt(c.decls[0].params.count, 2, "non_object_param_entry_skipped: only objects kept")
  assertEqual(c.decls[0].params[0].name, "a", "non_object_param_entry_skipped: p0")
  assertEqual(c.decls[0].params[1].name, "b", "non_object_param_entry_skipped: p1")
}

// Non-string entries in the `requiresClauses` array are coerced to ""
// rather than skipped (F# parity: matches safeStr empty-string default).
// This differs from the decl/param skip behaviour: non-string entries are
// preserved with empty-string placeholders, not dropped (#1240).
func testStrArrayNonStringElementCoercedToEmpty(): Unit {
  val json = "{\"decls\":[" + "  {\"name\":\"f\",\"requires\":[42, \"x > 0\", null]}" + "]}"
  val c = unwrapOrFail(parseFromJson(json), "str_array_coerce")
  assertEqualInt(c.decls[0].requiresClauses.count, 3, "str_array_coerce: count preserved")
  assertEqual(c.decls[0].requiresClauses[0], "", "str_array_coerce: number → empty")
  assertEqual(c.decls[0].requiresClauses[1], "x > 0", "str_array_coerce: string kept")
  assertEqual(c.decls[0].requiresClauses[2], "", "str_array_coerce: null → empty")
}

// v3 round-trip: formatVersion=3 with non-empty visibility, dependencies, and
// contractHash all parse correctly.  Exercises the new field paths added in
// #2701 (#2727).
func testParseV3Contract(): Unit {
  val json = "{" + "\"formatVersion\":3," + "\"packageName\":\"My.V3.Pkg\"," + "\"version\":\"2.0.0\"," +
    "\"level\":\"proof_required\"," +
    "\"contractHash\":\"abc123def456\"," +
    "\"dependencies\":[" +
    "  {\"packageName\":\"Dep.A\",\"version\":\"1.0.0\",\"contractHash\":\"hash-a\"}," +
    "  {\"packageName\":\"Dep.B\",\"version\":\"0.5.0\",\"contractHash\":\"hash-b\"}" +
    "]," +
    "\"decls\":[" +
    "  {\"kind\":\"func\",\"name\":\"compute\",\"repr\":\"func compute(): Int\",\"visibility\":\"pub\"}," +
    "  {\"kind\":\"func\",\"name\":\"helper\",\"repr\":\"func helper(): Unit\",\"visibility\":\"internal\"}" +
    "]}"
  val c = unwrapOrFail(parseFromJson(json), "v3_round_trip")
  assertEqualInt(c.formatVersion, 3, "v3: formatVersion")
  assertEqual(c.contractHash, "abc123def456", "v3: contractHash")
  assertEqualInt(c.dependencies.count, 2, "v3: two dependencies")
  assertEqual(c.dependencies[0].packageName, "Dep.A", "v3: dep[0].packageName")
  assertEqual(c.dependencies[0].version, "1.0.0", "v3: dep[0].version")
  assertEqual(c.dependencies[0].contractHash, "hash-a", "v3: dep[0].contractHash")
  assertEqual(c.dependencies[1].packageName, "Dep.B", "v3: dep[1].packageName")
  assertEqual(c.dependencies[1].contractHash, "hash-b", "v3: dep[1].contractHash")
  assertEqualInt(c.decls.count, 2, "v3: two decls")
  val dPub = findDecl(c.decls, "compute")
  match dPub {
    case None -> panic("v3: compute decl missing")
    case Some(d) -> assertEqual(d.visibility, "pub", "v3: compute.visibility = pub")
  }
  val dInternal = findDecl(c.decls, "helper")
  match dInternal {
    case None -> panic("v3: helper decl missing")
    case Some(d) -> assertEqual(d.visibility, "internal", "v3: helper.visibility = internal")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. In-process resource readers (#1229 Phase A.3)
// ─────────────────────────────────────────────────────────────────────────────
//
// Every Lyric-emitted assembly has an embedded contract resource so we can
// verify the in-process reader against the running test PE itself.
// The F# bootstrap emitter uses the legacy `Lyric.Contract` resource name;
// the self-hosted emitter uses the per-package `Lyric.Contract.<Pkg>` form.
// `readAllContractsFromFile` handles both forms; tests below use it so they
// pass regardless of which emitter produced this DLL.
func selfDllPath(): String {
  Path.join(Environment.appBaseDirectory(), "contract_meta_self_test.dll")
}

// `readAllContractsFromFile` reads the embedded contract JSON in-process via
// the metadata-direct reader (`Msil.MetadataReader`, no subprocess and no
// runtime `Assembly.Load`).  The bytes must round-trip through `parseFromJson`
// cleanly — pinning the read + parse pipeline used by the bridge's restored-dep
// loader.
func testReadFromFileInProcess(): Unit {
  val entries = readAllContractsFromFile(selfDllPath())
  assertTrue(entries.count >= 1, "read_from_file_in_process: at least one contract entry")
  var foundJson = false
  var i = 0
  while i < entries.count {
    if Str.isNotEmpty(entries[i].json) {
      foundJson = true
      val c = unwrapOrFail(parseFromJson(entries[i].json), "read_from_file_in_process")
      assertTrue(Str.isNotEmpty(c.packageName), "read_from_file_in_process: packageName present")
    }
    i = i + 1
  }
  assertTrue(foundJson, "read_from_file_in_process: at least one entry with non-empty JSON")
}

// `readAllContractsFromFile` surfaces at least one entry for a single-package
// Lyric assembly.  The F# bootstrap emitter embeds the legacy `Lyric.Contract`
// resource (packageName = ""); the self-hosted emitter embeds the per-package
// `Lyric.Contract.<Pkg>` resource (non-empty packageName).  Either form is
// acceptable here — we only assert that at least one entry with valid JSON
// is present.
func testReadAllContractsFromFileSinglePkg(): Unit {
  val entries = readAllContractsFromFile(selfDllPath())
  assertTrue(entries.count >= 1, "read_all_single_pkg: at least one entry")
  var foundEntry = false
  var i = 0
  while i < entries.count {
    if Str.isNotEmpty(entries[i].json) {
      foundEntry = true
    }
    i = i + 1
  }
  assertTrue(foundEntry, "read_all_single_pkg: at least one entry with non-empty JSON")
}

// Error-path contract (#3201): the metadata-direct readers return `None` / `[]`
// — never throw — on a missing file or a present-but-not-a-managed-PE file.
// This pins the graceful-failure behaviour the bridge's restored-dep loader
// relies on (it pre-checks existence but treats a non-Lyric DLL as "no
// contract"), and guards against a regression back to the old throwing
// `Assembly.Load(byte[])` shape, which raised `FileNotFoundException` /
// `BadImageFormatException` on these same inputs.
func testReadErrorPathsGraceful(): Unit {
  // (1) Missing file: openResourceImage's File.readBytes errors -> None / [].
  val missing = Path.join(Environment.appBaseDirectory(), "__cm_selftest_missing.dll")
  match readFromFile(missing) {
    case None -> ()
    case Some(_) -> panic("read_error_paths: readFromFile(missing) should be None")
  }
  assertEqualInt(
    readAllContractsFromFile(missing).count,
    0,
    "read_error_paths: readAllContractsFromFile(missing) empty"
  )

  // (2) Present file that is not a managed PE image: readPe rejects the bytes
  //     (no 'MZ' signature) -> None / [].
  val notDll = Path.join(Environment.appBaseDirectory(), "__cm_selftest_notdll.bin")
  match File.writeText(notDll, "this is not a PE image") {
    case Ok(_) -> ()
    case Err(e) -> panic("read_error_paths: could not write fixture: " + IOError.message(e))
  }
  // Capture both results before asserting: a panic in an assertion must not
  // bypass the cleanup and leak the fixture across runs (#3226).  Lyric has
  // no try/finally, so delete-before-assert is the deterministic ordering.
  val readResult = readFromFile(notDll)
  val allCount = readAllContractsFromFile(notDll).count

  // Best-effort cleanup so the fixture does not linger in the test output
  // directory (where the running test DLL lives) across runs.  A failed
  // delete is non-fatal — the reads above have already happened.
  match File.deleteFile(notDll) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  match readResult {
    case None -> ()
    case Some(_) -> panic("read_error_paths: readFromFile(non-PE) should be None")
  }
  assertEqualInt(allCount, 0, "read_error_paths: readAllContractsFromFile(non-PE) empty")
}

// Note: the `readAllContractsFromFile` step-2 path — per-package
// `Lyric.Contract.<Pkg>` resources extracted from project-as-DLL assemblies —
// is not covered here because no fixture bundled DLL with multiple
// `Lyric.Contract.*` resources is available in this test context.  Coverage
// for that path is deferred until Phase A.3.2 has an end-to-end fixture.
// ─────────────────────────────────────────────────────────────────────────────
// §4. JSON serialisation (contractToJson)
// ─────────────────────────────────────────────────────────────────────────────
// escapeJson covers the printable-ASCII passthrough plus the five
// always-escaped sequences: `"`, `\`, `\n`, `\r`, `\t`.
func testEscapeJsonBasic(): Unit {
  assertEqual(escapeJson("hello"), "hello", "escape_json_basic: printable passthrough")
  assertEqual(escapeJson("a\"b"), "a\\\"b", "escape_json_basic: quote escapes")
  assertEqual(escapeJson("a\\b"), "a\\\\b", "escape_json_basic: backslash escapes")
  assertEqual(escapeJson("line1\nline2"), "line1\\nline2", "escape_json_basic: newline escapes")
  assertEqual(escapeJson("a\rb"), "a\\rb", "escape_json_basic: carriage-return escapes (#1340)")
  assertEqual(escapeJson("a\tb"), "a\\tb", "escape_json_basic: tab escapes")
}

// A `Contract` → JSON → `Contract` round-trip preserves every field
// the parser exposes.  This is the strongest invariant: the JSON
// emitted by `contractToJson` must round-trip through `parseFromJson`
// to the identical structure.
func testContractToJsonRoundTrip(): Unit {
  // Build a contract with a non-trivial mix of fields.
  val params: List[ContractParam] = newList()
  params.add(ContractParam(name = "x", ty = "Int"))
  params.add(ContractParam(name = "y", ty = "in slice[Byte]"))
  val reqClauses: List[String] = newList()
  reqClauses.add("x >= 0")
  val ensClauses: List[String] = newList()
  ensClauses.add("result == x + 1")
  val decls: List[ContractDecl] = newList()
  decls.add(
    ContractDecl(
      kind = "func",
      name = "succ",
      repr = "pub func succ(x: in Int): Int",
      visibility = "pub",
      isPure = true,
      stability = "stable:0.1",
      requiresClauses = reqClauses,
      ensuresClauses = ensClauses,
      body = Some(value = "x + 1"),
      params = params,
      bmode = false
    )
  )
  val original = Contract(
    packageName = "RoundTrip.Pkg",
    version = "1.2.3",
    level = "runtime_checked",
    purity = "",
    formatVersion = 2,
    decls = decls,
    dependencies = newList(),
    imports = newList(),
    wholeImports = newList(),
    selectedImports = newList(),
    contractHash = ""
  )

  val json = contractToJson(original)
  val parsed = unwrapOrFail(parseFromJson(json), "round_trip")

  // Validate the structural fields.
  assertEqual(parsed.packageName, original.packageName, "round_trip: packageName")
  assertEqual(parsed.version, original.version, "round_trip: version")
  assertEqual(parsed.level, original.level, "round_trip: level")
  assertEqualInt(parsed.formatVersion, original.formatVersion, "round_trip: formatVersion")
  assertEqualInt(parsed.decls.count, 1, "round_trip: one decl")
  val d = parsed.decls[0]
  assertEqual(d.kind, "func", "round_trip: decl.kind")
  assertEqual(d.name, "succ", "round_trip: decl.name")
  assertEqual(d.repr, "pub func succ(x: in Int): Int", "round_trip: decl.repr")
  assertTrue(d.isPure, "round_trip: decl.isPure")
  assertEqual(d.stability, "stable:0.1", "round_trip: decl.stability")
  assertEqualInt(d.requiresClauses.count, 1, "round_trip: requires count")
  assertEqual(d.requiresClauses[0], "x >= 0", "round_trip: requires[0]")
  assertEqualInt(d.ensuresClauses.count, 1, "round_trip: ensures count")
  assertEqual(d.ensuresClauses[0], "result == x + 1", "round_trip: ensures[0]")
  match d.body {
    case Some(b) -> assertEqual(b, "x + 1", "round_trip: body")
    case None -> panic("round_trip: expected body Some")
  }
  assertEqualInt(d.params.count, 2, "round_trip: param count")
  assertEqual(d.params[0].name, "x", "round_trip: param[0].name")
  assertEqual(d.params[0].ty, "Int", "round_trip: param[0].ty")
  assertEqual(d.params[1].name, "y", "round_trip: param[1].name")
  assertEqual(d.params[1].ty, "in slice[Byte]", "round_trip: param[1].ty")
}

// A `ContractDecl` with default values for every optional field
// emits a JSON object that has ONLY the three required keys (kind,
// name, repr).  Mirrors the F# producer's
// "skip empty optional fields" convention so the JSON byte-stables
// across implementations.
func testContractToJsonOmitsDefaults(): Unit {
  val noParams: List[ContractParam] = newList()
  val empty: List[String] = newList()
  val decls: List[ContractDecl] = newList()
  decls.add(
    ContractDecl(
      kind = "record",
      name = "Point",
      repr = "pub record Point { x: Int, y: Int }",
      visibility = "pub",
      isPure = false,
      stability = "",
      requiresClauses = empty,
      ensuresClauses = empty,
      body = None,
      params = noParams,
      bmode = false
    )
  )
  val c = Contract(
    packageName = "Geom",
    version = "0.1.0",
    level = "runtime_checked",
    purity = "",
    formatVersion = 2,
    decls = decls,
    dependencies = newList(),
    imports = newList(),
    wholeImports = newList(),
    selectedImports = newList(),
    contractHash = ""
  )
  val json = contractToJson(c)
  assertTrue(not Str.contains(json, "\"stability\""), "omits_defaults: empty stability key absent")
  assertTrue(not Str.contains(json, "\"pure\""), "omits_defaults: false pure key absent")
  assertTrue(not Str.contains(json, "\"requires\""), "omits_defaults: empty requires absent")
  assertTrue(not Str.contains(json, "\"ensures\""), "omits_defaults: empty ensures absent")
  assertTrue(not Str.contains(json, "\"body\""), "omits_defaults: None body absent")
  assertTrue(not Str.contains(json, "\"params\""), "omits_defaults: empty params absent")
  assertTrue(not Str.contains(json, "\"bmode\""), "omits_defaults: false bmode key absent")
}

// ─────────────────────────────────────────────────────────────────────────────
// §6. buildContractFromFile / levelOfFile coverage (#1366)
// ─────────────────────────────────────────────────────────────────────────────
//
// These tests parse a small Lyric source string and run the contract
// builder over it.  Each branch the round-trip JSON tests cannot reach
// is exercised here: file-level annotation classification, opaque
// types, multi-case enums, generic interfaces, unions with mixed
// named + positional fields, and the `TAValue` (array size) generic
// argument path.
func findDeclByKind(decls: in List[ContractDecl], kind: in String, name: in String): Option[ContractDecl] {
  var i = 0
  while i < decls.count {
    val d = decls[i]
    if d.kind == kind and d.name == name {
      return Some(value = d)
    }
    i = i + 1
  }
  None
}

func unwrapDeclOrFail(opt: in Option[ContractDecl], label: in String): ContractDecl {
  match opt {
    case Some(d) -> d
    case None -> {
      panic(label + ": expected decl, found none")
      ContractDecl(
        kind = "",
        name = "",
        repr = "",
        visibility = "",
        isPure = false,
        stability = "",
        requiresClauses = newList(),
        ensuresClauses = newList(),
        body = None,
        params = newList(),
        bmode = false
      )
    }
  }
}

// `levelOfFile` returns "runtime_checked" for unannotated files.
func testLevelOfFileDefault(): Unit {
  val src = "package P\n\npub func f(): Int { 1 }\n"
  val pr = parse(src)
  assertEqual(levelOfFile(pr.file), "runtime_checked", "levelOfFile: unannotated → runtime_checked")
}

// `levelOfFile` returns "axiom" for `@axiom` file-level annotation.
func testLevelOfFileAxiom(): Unit {
  val src = "@axiom\npackage P\n\npub func ax(): Int { 1 }\n"
  val pr = parse(src)
  assertEqual(levelOfFile(pr.file), "axiom", "levelOfFile: @axiom → axiom")
}

// `levelOfFile` returns "proof_required" without modifier.
func testLevelOfFileProofRequired(): Unit {
  val src = "@proof_required\npackage P\n\npub func pf(): Int { 1 }\n"
  val pr = parse(src)
  assertEqual(levelOfFile(pr.file), "proof_required", "levelOfFile: @proof_required → proof_required")
}

// `levelOfFile` returns "proof_required(unsafe_blocks_allowed)" for
// the unsafe_blocks_allowed modifier (#1371).
func testLevelOfFileProofRequiredUnsafeBlocks(): Unit {
  val src = "@proof_required(unsafe_blocks_allowed)\npackage P\n\npub func pf(): Int { 1 }\n"
  val pr = parse(src)
  assertEqual(
    levelOfFile(pr.file),
    "proof_required(unsafe_blocks_allowed)",
    "levelOfFile: @proof_required(unsafe_blocks_allowed) → proof_required(unsafe_blocks_allowed)"
  )
}

// `levelOfFile` returns "proof_required(checked_arithmetic)" for
// the checked_arithmetic modifier (#1371).
func testLevelOfFileProofRequiredCheckedArith(): Unit {
  val src = "@proof_required(checked_arithmetic)\npackage P\n\npub func pf(): Int { 1 }\n"
  val pr = parse(src)
  assertEqual(
    levelOfFile(pr.file),
    "proof_required(checked_arithmetic)",
    "levelOfFile: @proof_required(checked_arithmetic) → proof_required(checked_arithmetic)"
  )
}

// `buildContractFromFile` covers opaque types (reprForOpaque).
func testBuildOpaque(): Unit {
  val src = "package P\n\npub opaque type Money { amount: Int }\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "opaque", "Money"), "buildContractFromFile: opaque Money missing")
  assertTrue(Str.contains(d.repr, "pub opaque type Money"), "opaque: repr header present (got " + d.repr + ")")
  assertTrue(Str.contains(d.repr, "amount: Int"), "opaque: amount field present")
}

// `buildContractFromFile` covers multi-case enums (reprForEnum).  The
// repr must prefix each variant with `case` so the synthesised contract
// source re-parses (a bare `{ Red, Green, Blue }` triggers P0140
// "expected 'case' to start an enum case" when a consumer restores the
// DLL and re-typechecks its public surface).
func testBuildEnum(): Unit {
  val src = "package P\n\npub enum Color {\n  case Red\n  case Green\n  case Blue\n}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "enum", "Color"), "buildContractFromFile: enum Color missing")
  assertTrue(Str.contains(d.repr, "case Red"), "enum: 'case Red' present (got " + d.repr + ")")
  assertTrue(Str.contains(d.repr, "case Green"), "enum: 'case Green' present (got " + d.repr + ")")
  assertTrue(Str.contains(d.repr, "case Blue"), "enum: 'case Blue' present (got " + d.repr + ")")
  // The repr must round-trip through the parser cleanly — this is what a
  // cross-package consumer does when synthesising the restored contract.
  val rt = parse("package P\n\n" + d.repr + "\n")
  assertEqualInt(rt.diagnostics.count, 0, "enum: repr re-parses with no diagnostics (got " + d.repr + ")")
}

// `buildContractFromFile` emits a `pub protected type` as an opaque-type
// anchor (reprForProtected) so a cross-package consumer can resolve the
// name in a public signature without seeing the locked internal state.
// Protected types are emitted regardless of source visibility.
func testBuildProtected(): Unit {
  val src = "package P\n\npub protected type Counter {\n  var n: Int = 0\n  entry bump(): Unit { n = n + 1 }\n}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(
    findDeclByKind(c.decls, "opaque", "Counter"),
    "buildContractFromFile: protected Counter missing"
  )
  assertTrue(Str.contains(d.repr, "pub opaque type Counter"), "protected: opaque repr header (got " + d.repr + ")")
  val rt = parse("package P\n\n" + d.repr + "\n")
  assertEqualInt(rt.diagnostics.count, 0, "protected: repr re-parses with no diagnostics (got " + d.repr + ")")
}

// `buildContractFromFile` covers generic interfaces.
func testBuildGenericInterface(): Unit {
  val src = "package P\n\npub interface Box[T] {\n  func get(): T\n}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "interface", "Box"), "buildContractFromFile: interface Box missing")
  assertTrue(Str.contains(d.repr, "Box[T]"), "interface: generic param list present (got " + d.repr + ")")
  assertTrue(Str.contains(d.repr, "func get()"), "interface: method get() present")
}

// An interface's default method rides in the repr with its body, so it
// re-parses as a default (`IMFunc`), not an abstract member (#7575 review).
func testBuildInterfaceDefaultMethod(): Unit {
  val src = "package P\n\npub interface Sized {\n  func size(): Int\n  func isEmpty(): Bool {\n    self.size() == 0\n  }\n  func twice(): Int = self.size() * 2\n}\n"
  val c = buildContractFromFile(parse(src).file, "1.0.0")
  val d = unwrapDeclOrFail(
    findDeclByKind(c.decls, "interface", "Sized"),
    "buildContractFromFile: interface Sized missing"
  )
  val rt = parse("package P\n\n" + d.repr + "\n")
  assertEqualInt(rt.diagnostics.count, 0, "interface default: repr re-parses (got " + d.repr + ")")
  var sigs = 0
  var defaults = 0
  for it in rt.file.items {
    match it.kind {
      case IInterface(ix) -> {
        for m in ix.members {
          match m {
            case IMSig(_) -> {
              sigs = sigs + 1
            }
            case IMFunc(_) -> {
              defaults = defaults + 1
            }
            case _ -> ()
          }
        }
      }
      case _ -> ()
    }
  }
  assertEqualInt(sigs, 1, "interface default: one abstract member (got " + d.repr + ")")
  assertEqualInt(defaults, 2, "interface default: both defaults kept as defaults (got " + d.repr + ")")
}

// `buildContractFromFile` covers unions with mixed positional + named
// payloads — UFPos via the bare-type form (`Circle(Int)`) and UFNamed
// via the labelled form (`Square(side: Int)`).  Both branches of
// `renderUnionCase` are exercised (#1370).
func testBuildUnionMixedFields(): Unit {
  val src = "package P\n\npub union Shape {\n" + "  case Circle(Int)\n" + "  case Square(side: Int)\n" + "}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "union", "Shape"), "buildContractFromFile: union Shape missing")
  assertTrue(Str.contains(d.repr, "Circle"), "union: Circle case present")
  assertTrue(Str.contains(d.repr, "Square"), "union: Square case present")
}

// `renderTypeArg` covers the `TAValue` (integer-literal array size)
// branch via a fixed-size array field in a public record.
func testBuildArrayTypeArg(): Unit {
  val src = "package P\n\npub record Buf { bytes: array[4, Int] }\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "record", "Buf"), "buildContractFromFile: record Buf missing")
  assertTrue(Str.contains(d.repr, "array[4, Int]"), "array: TAValue literal renders faithfully (got " + d.repr + ")")
}

// `buildContractFromFile` carries the supplied version.
func testBuildVersionThreaded(): Unit {
  val src = "package P\n\npub func f(): Int { 1 }\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "2.3.4")
  assertEqual(c.version, "2.3.4", "buildContractFromFile: version argument carried through")
}

// `buildContractFromFile` embeds a GENERIC pub function's real body
// (`funcDecl`/`funcBodyText`) — a generic Lyric function never gets a
// callable cross-assembly MemberRef in the compiled DLL, so a restored
// consumer's `Lyric.Mono.monoFileWithImports` needs the body to specialise
// a concrete copy at the call site (#6363, #6364, #6365).
func testBuildGenericFuncCarriesBody(): Unit {
  val src = "package P\n\npub func unwrapOr[T](o: in Option[T], default: in T): T {\n" + "  match o {\n" +
    "    case Some(v) -> v\n" +
    "    case None -> default\n" +
    "  }\n" +
    "}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "unwrapOr"), "buildContractFromFile: func unwrapOr missing")
  assertTrue(not Str.contains(d.repr, "match"), "generic_func_body: repr stays bodyless (got " + d.repr + ")")
  match d.body {
    case None -> panic("generic_func_body: expected Some(body), got None")
    case Some(b) -> {
      assertTrue(Str.contains(b, "match o"), "generic_func_body: body carries the match expression (got " + b + ")")
      assertTrue(Str.contains(b, "Some(v)"), "generic_func_body: body carries the Some arm")
      assertTrue(Str.contains(b, "default"), "generic_func_body: body carries the None arm")
      // The spliced-in body must re-parse cleanly onto the bodyless repr head.
      val rt = parse("package P\n\n" + d.repr + " " + b + "\n")
      assertEqualInt(rt.diagnostics.count, 0, "generic_func_body: repr + body re-parses (got " + b + ")")
    }
  }
}

// An expression-bodied generic function (`= expr`) carries its body in
// the `= expr` form, not the block form.
func testBuildGenericFuncExprBodyCarriesBody(): Unit {
  val src = "package P\n\npub func identity[T](x: in T): T = x\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "identity"), "buildContractFromFile: func identity missing")
  match d.body {
    case None -> panic("generic_func_expr_body: expected Some(body), got None")
    case Some(b) -> {
      assertTrue(Str.startsWith(b, "="), "generic_func_expr_body: expr body starts with '=' (got " + b + ")")
      assertTrue(Str.contains(b, "x"), "generic_func_expr_body: body carries the expression")
      val rt = parse("package P\n\n" + d.repr + " " + b + "\n")
      assertEqualInt(rt.diagnostics.count, 0, "generic_func_expr_body: repr + body re-parses (got " + b + ")")
    }
  }
}

// An `@externTarget` generic function's `= ()` body is a required-but-fake
// placeholder — the named BCL/JDK member (or, for a handful of kernel
// collection primitives, a compiler-recognised intrinsic keyed on the
// function's bare name) is its real implementation.  It must keep
// `body = None`: feeding the placeholder into `Lyric.Mono` as if it were
// real Lyric source would specialise a copy that actually computes and
// returns `()`, silently discarding the FFI dispatch and baking a genuine
// return-type mismatch into working IL.
func testBuildExternTargetGenericFuncHasNoBody(): Unit {
  val src = "package P\n\nextern type List[T] = \"System.Collections.Generic.List`1\"\n\n" +
    "@externTarget(\"System.Collections.Generic.List`1..ctor\")\n" +
    "pub func newList[T](): List[T] = ()\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "newList"), "buildContractFromFile: func newList missing")
  match d.body {
    case None -> ()
    case Some(_) -> panic("extern_target_func_no_body: expected None, got Some")
  }
}

// A NON-generic pub function keeps `body = None` — it compiles to a real
// cross-assembly MemberRef, so a restored consumer calls it directly and
// never needs to reconstruct its implementation from source.
func testBuildNonGenericFuncHasNoBody(): Unit {
  val src = "package P\n\npub func addOne(x: in Int): Int {\n  x + 1\n}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "addOne"), "buildContractFromFile: func addOne missing")
  match d.body {
    case None -> ()
    case Some(_) -> panic("non_generic_func_no_body: expected None, got Some")
  }
}

// `buildContractFromFile` embeds the `around` body of an `@inline_template`
// aspect (D047/D050) so a consuming package can later resolve a
// `from`-instance against a restored dependency (#3543 defect 4).  The
// fixture mirrors `Auth.Aspects.ValidateKey` (lyric-auth): its body
// contains string-literal error messages with embedded double quotes —
// exactly the shape that breaks a naive (unescaped) string concatenation
// into the contract JSON.  `buildContractFromFile` must route the body
// through `escapeJson` (via `ContractDecl.body` / `renderDecl`), so
// `contractToJson` produces valid JSON and `parseFromJson` round-trips
// the body text unchanged.
func testBuildInlineTemplateAspectBody(): Unit {
  val src = "@runtime_checked\n" + "package P\n\n" + "@inline_template\n" + "pub aspect ValidateKey {\n" +
    "  config {\n" +
    "    enabled: Bool = true\n" +
    "    expectedKey: String\n" +
    "  }\n" +
    "  around(call) -> ret {\n" +
    "    if not enabled {\n" +
    "      ret = call.proceed()\n" +
    "    } else {\n" +
    "      if args.apiKey == \"\" {\n" +
    "        ret = Err(\"API key is missing\")\n" +
    "      } else {\n" +
    "        val ok = Auth.verifyApiKey(args.apiKey, expectedKey)\n" +
    "        if ok {\n" +
    "          ret = call.proceed()\n" +
    "        } else {\n" +
    "          ret = Err(\"API key is invalid\")\n" +
    "        }\n" +
    "      }\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "inline_template aspect body: fixture parses cleanly")
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(
    findDeclByKind(c.decls, "aspect", "ValidateKey"),
    "buildContractFromFile: aspect ValidateKey missing"
  )
  match d.body {
    case None -> panic("inline_template aspect body: body field must be Some(...)")
    case Some(b) -> {
      assertTrue(
        Str.contains(b, "API key is missing"),
        "inline_template aspect body: message text preserved (got " + b + ")"
      )
      assertTrue(
        Str.contains(b, "API key is invalid"),
        "inline_template aspect body: second message preserved (got " + b + ")"
      )
    }
  }
  // The whole contract must serialise to well-formed JSON and round-trip:
  // parsing the rendered JSON back must recover the same body text. A
  // naive unescaped embed would corrupt the JSON at the first `"` inside
  // the body and either fail to parse or truncate the string.
  val json = contractToJson(c)
  val reparsed = unwrapOrFail(parseFromJson(json), "inline_template aspect body: contractToJson output must parse")
  val d2 = unwrapDeclOrFail(
    findDeclByKind(reparsed.decls, "aspect", "ValidateKey"),
    "round-trip: aspect ValidateKey missing"
  )
  match d2.body {
    case None -> panic("round-trip: body field lost")
    case Some(b2) -> {
      assertTrue(Str.contains(b2, "API key is missing"), "round-trip: message text preserved (got " + b2 + ")")
      assertTrue(Str.contains(b2, "API key is invalid"), "round-trip: second message preserved (got " + b2 + ")")
      // The stored body text must itself be re-parseable Lyric source — not
      // just JSON-safe. Feed it back through `parse` wrapped in a minimal
      // aspect declaration; a bare-space statement separator (instead of
      // "; ") would make this fail for any multi-statement `around` body.
      val rt = parse("package P\n\npub aspect Rt {\n  " + b2 + "\n}\n")
      assertEqualInt(rt.diagnostics.count, 0, "round-trip: body text re-parses as valid Lyric source (got " + b2 + ")")
    }
  }
  // The repr itself must also re-parse standalone: `restored_packages.l`
  // synthesises a preamble straight from `repr`, so `around(...)` without
  // its own `{}` block (even though the real body lives in `.body`) would
  // fail to parse when a restored dependency's preamble is rebuilt.
  val reprRt = parse("package P\n\n" + d.repr + "\n")
  assertEqualInt(
    reprRt.diagnostics.count,
    0,
    "inline_template aspect repr: re-parses as valid Lyric source (got " + d.repr + ")"
  )
}

// `aspectBodyText` must separate statements with `"; "` (matching
// `Lyric.Fmt.blockInline`), not a bare space — Lyric's statement-end
// insertion only fires at newlines, so an inline single-line block with
// two or more statements needs an explicit separator to re-parse.
func testBuildInlineTemplateAspectBodyMultiStatement(): Unit {
  val src = "package P\n\n" + "@inline_template\n" + "pub aspect TwoStmt {\n" + "  around(call) -> ret {\n" +
    "    val x = 1\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val pr = parse(src)
  assertEqualInt(pr.diagnostics.count, 0, "multi-statement aspect body: fixture parses cleanly")
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(
    findDeclByKind(c.decls, "aspect", "TwoStmt"),
    "buildContractFromFile: aspect TwoStmt missing"
  )
  match d.body {
    case None -> panic("multi-statement aspect body: body field must be Some(...)")
    case Some(b) -> {
      val rt = parse("package P\n\npub aspect Rt {\n  " + b + "\n}\n")
      assertEqualInt(
        rt.diagnostics.count,
        0,
        "multi-statement aspect body: re-parses as valid Lyric source (got " + b + ")"
      )
    }
  }
}

// A private (non-`pub`) aspect never crosses the contract boundary,
// `around` body or not — only `pub`-visibility aspects are candidates for
// cross-package `from`-instance resolution.
func testBuildPrivateAspectOmitted(): Unit {
  val src = "package P\n\n" + "aspect Local {\n" + "  matches: name like \"h*\"\n" + "  around(call) -> ret {\n" +
    "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  match findDeclByKind(c.decls, "aspect", "Local") {
    case None -> ()
    case Some(_) -> panic("buildContractFromFile: private aspect must not appear in contract decls")
  }
}

// A `pub aspect` with an `around` body and no `@inline_template` is a
// B'-mode template (docs/55): it now carries into the contract (tagged
// `bmode = true`) so a consuming package's `from`-instance can resolve it
// from a restored dependency, same as a C-mode (`@inline_template`)
// template already did.
func testBuildBModeAspectIncluded(): Unit {
  val src = "package P\n\n" + "pub aspect Tap {\n" + "  around(call) -> ret {\n" + "    ret = call.proceed()\n" +
    "  }\n" +
    "}\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val d = unwrapDeclOrFail(
    findDeclByKind(c.decls, "aspect", "Tap"),
    "buildContractFromFile: B'-mode aspect Tap missing"
  )
  assertTrue(d.bmode, "B'-mode aspect is tagged bmode = true")
  match d.body {
    case Some(_) -> ()
    case None -> panic(
      "buildContractFromFile: B'-mode aspect body must still be embedded (needed by the weaver either way)"
    )
  }
}

// `buildContractFromFile` filters out non-pub items.
func testBuildFiltersNonPub(): Unit {
  val src = "package P\n\nfunc internalOnly(): Int { 1 }\n" + "pub func publicOne(): Int { 1 }\n"
  val pr = parse(src)
  val c = buildContractFromFile(pr.file, "1.0.0")
  val nonPub = findDeclByKind(c.decls, "func", "internalOnly")
  match nonPub {
    case None -> ()
    case Some(_) -> panic("buildContractFromFile: non-pub item leaked into decls")
  }
  val pubd = findDeclByKind(c.decls, "func", "publicOne")
  match pubd {
    case Some(_) -> ()
    case None -> panic("buildContractFromFile: pub item missing from decls")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Test items
// ─────────────────────────────────────────────────────────────────────────────
test "minimal valid contract round-trips" {
  testMinimal()
}

test "empty object defaults" {
  testEmptyObjectDefaults()
}

test "empty string returns None" {
  testEmptyStringReturnsNone()
}

test "non-object root returns None" {
  testNonObjectRootReturnsNone()
}

test "malformed JSON returns None" {
  testMalformedJsonReturnsNone()
}

test "pure and contracts" {
  testPureAndContracts()
}

test "body optional" {
  testBodyOptional()
}

test "params array" {
  testParamsArray()
}

test "stability field" {
  testStability()
}

test "multiple decls order" {
  testMultipleDeclsOrder()
}

test "pure defaults to false" {
  testPureDefaultsFalse()
}

test "non-object decl entry skipped" {
  testNonObjectDeclEntrySkipped()
}

test "non-array decls field skipped" {
  testNonArrayDeclsFieldSkipped()
}

test "readFromFile in process" {
  testReadFromFileInProcess()
}

test "readAllContractsFromFile single pkg" {
  testReadAllContractsFromFileSinglePkg()
}

test "read error paths graceful (missing + non-PE)" {
  testReadErrorPathsGraceful()
}

test "non-object param entry skipped" {
  testNonObjectParamEntrySkipped()
}

test "str array non-string element coerced to empty" {
  testStrArrayNonStringElementCoercedToEmpty()
}

test "parse v3 contract round-trip" {
  testParseV3Contract()
}

test "escapeJson basic" {
  testEscapeJsonBasic()
}

test "contractToJson round-trip" {
  testContractToJsonRoundTrip()
}

// docs/01 §9.2 (D141, #7555, #7558): a contract records its package's import
// forms, so a consumer's whole import reaches only the packages it imports
// whole, and a restored generic body sees its selective imports.
test "a contract records its whole and selective imports and round-trips them" {
  val src = "package P\n\nimport Q\nimport R.{f, T}\nimport S as Z\n\npub func g(): Int { 1 }\n"
  val c = buildContractFromFile(parse(src).file, "1.0.0")
  assertEqualInt(c.imports.count, 3, "every import is listed")
  assertEqualInt(c.wholeImports.count, 1, "one whole import")
  assertEqual(c.wholeImports[0], "Q", "Q is imported whole")
  assertEqualInt(c.selectedImports.count, 2, "two selectively imported names")
  assertEqual(c.selectedImports[0], "R::f", "R::f")
  assertEqual(c.selectedImports[1], "R::T", "R::T")
  val parsed = unwrapOrFail(parseFromJson(contractToJson(c)), "import forms")
  assertEqualInt(parsed.wholeImports.count, 1, "wholeImports round-trips")
  assertEqual(parsed.wholeImports[0], "Q", "wholeImports[0] round-trips")
  assertEqualInt(parsed.selectedImports.count, 2, "selectedImports round-trips")
  assertEqual(parsed.selectedImports[1], "R::T", "selectedImports[1] round-trips")
}

test "a contract without wholeImports reads its imports as whole" {
  val json = "{\"packageName\": \"Old\", \"version\": \"1.0.0\", \"imports\": [\"A\", \"B\"], \"decls\": []}"
  val parsed = unwrapOrFail(parseFromJson(json), "legacy imports")
  assertEqualInt(parsed.wholeImports.count, 2, "both imports count as whole")
  assertEqualInt(parsed.selectedImports.count, 0, "no selective imports recorded")
}

test "contractToJson omits defaults" {
  testContractToJsonOmitsDefaults()
}

test "levelOfFile default" {
  testLevelOfFileDefault()
}

test "levelOfFile axiom" {
  testLevelOfFileAxiom()
}

test "levelOfFile proof_required" {
  testLevelOfFileProofRequired()
}

test "levelOfFile proof_required unsafe_blocks_allowed" {
  testLevelOfFileProofRequiredUnsafeBlocks()
}

test "levelOfFile proof_required checked_arithmetic" {
  testLevelOfFileProofRequiredCheckedArith()
}

test "buildContractFromFile opaque" {
  testBuildOpaque()
}

test "buildContractFromFile enum" {
  testBuildEnum()
}

test "buildContractFromFile protected" {
  testBuildProtected()
}

test "buildContractFromFile generic interface" {
  testBuildGenericInterface()
}

test "buildContractFromFile interface default methods" {
  testBuildInterfaceDefaultMethod()
}

test "buildContractFromFile union mixed fields" {
  testBuildUnionMixedFields()
}

test "buildContractFromFile array type arg" {
  testBuildArrayTypeArg()
}

test "buildContractFromFile version threaded" {
  testBuildVersionThreaded()
}

test "buildContractFromFile generic func carries body" {
  testBuildGenericFuncCarriesBody()
}

test "buildContractFromFile generic func expr body carries body" {
  testBuildGenericFuncExprBodyCarriesBody()
}

test "buildContractFromFile non-generic func has no body" {
  testBuildNonGenericFuncHasNoBody()
}

test "buildContractFromFile externTarget generic func has no body" {
  testBuildExternTargetGenericFuncHasNoBody()
}

test "buildContractFromFile filters non-pub" {
  testBuildFiltersNonPub()
}

test "buildContractFromFile inline_template aspect body escapes and round-trips" {
  testBuildInlineTemplateAspectBody()
}

test "buildContractFromFile inline_template aspect body multi-statement separator" {
  testBuildInlineTemplateAspectBodyMultiStatement()
}

test "buildContractFromFile omits private aspects" {
  testBuildPrivateAspectOmitted()
}

test "buildContractFromFile includes B'-mode pub aspects tagged bmode = true" {
  testBuildBModeAspectIncluded()
}

// A literal `val` crosses a package boundary as an inlined `Int`, so a
// value outside `Int` stays out of the contract instead of arriving
// truncated (#7403).
test "buildContractFromFile carries only Int-range literal vals" {
  val src = "package P\n\npub val small: Long = -7\npub val big: Long = -5000000000\npub val huge: Long = 5000000000\npub val top: Int = 2147483647\n"
  val c = buildContractFromFile(parse(src).file, "1.0.0")
  assertTrue(isSomeDecl(findDeclByKind(c.decls, "val", "small")), "an in-range negative val is carried")
  assertTrue(not isSomeDecl(findDeclByKind(c.decls, "val", "big")), "a negative val below Int is omitted")
  assertTrue(not isSomeDecl(findDeclByKind(c.decls, "val", "huge")), "a positive val above Int is omitted")
  assertTrue(isSomeDecl(findDeclByKind(c.decls, "val", "top")), "Int.MaxValue is carried")
}

// A record method's `@pure` rides in its repr so a restored consumer's
// contract clauses may call it (#7383, #7395).
test "buildContractFromFile keeps @pure on a record method" {
  val src = "package P\n\npub record Money {\n  amount: Int\n  @pure\n  func isPositive(self: in Money): Bool { self.amount > 0 }\n  func bump(self: in Money): Money { self }\n}\n"
  val c = buildContractFromFile(parse(src).file, "1.0.0")
  val d = unwrapDeclOrFail(findDeclByKind(c.decls, "record", "Money"), "record Money missing")
  assertTrue(Str.contains(d.repr, "@pure func isPositive"), "@pure carried (got " + d.repr + ")")
  assertTrue(not Str.contains(d.repr, "@pure func bump"), "no @pure on an impure method")
  val rt = parse("package P\n\n" + d.repr + "\n")
  assertEqualInt(rt.diagnostics.count, 0, "the repr re-parses (got " + d.repr + ")")
}

func isSomeDecl(o: in Option[ContractDecl]): Bool {
  match o {
    case Some(_) -> true
    case None -> false
  }
}

// A package-level `@pure` / `@io` is the package's `[layers]` class
// (docs/65 §5, D149); it crosses into the contract's `purity`, which the
// JSON carries only when set.
test "buildContractFromFile records the package class and JSON round-trips it" {
  val pure = buildContractFromFile(parse("@pure\npackage P\n\npub func f(): Int = 1\n").file, "1.0.0")
  assertEqual(pure.purity, "pure", "@pure package")
  val io = buildContractFromFile(parse("@runtime_checked\n@io\npackage P\n").file, "1.0.0")
  assertEqual(io.purity, "io", "@io package")
  assertEqual(io.level, "runtime_checked", "the level is unaffected")
  val plain = buildContractFromFile(parse("package P\n").file, "1.0.0")
  assertEqual(plain.purity, "", "unclassified package")
  assertTrue(not Str.contains(contractToJson(plain), "\"purity\""), "no purity key when unclassified")
  val json = contractToJson(pure)
  assertTrue(Str.contains(json, "\"purity\": \"pure\""), "purity key written")
  val back = unwrapOrFail(parseFromJson(json), "purity round trip")
  assertEqual(back.purity, "pure", "purity read back")
}

// A function's `@io` crosses into its repr so a restored consumer's
// signature carries it (D149), and the repr still re-parses.
test "buildContractFromFile keeps @io on a function" {
  val c = buildContractFromFile(
    parse("@pure\npackage P\n\n@io\npub func now(): Int = 1\npub func pure1(): Int = 2\n").file,
    "1.0.0"
  )
  val io = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "now"), "func now missing")
  assertTrue(Str.startsWith(io.repr, "@io pub func now"), "@io carried (got " + io.repr + ")")
  val plain = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "pure1"), "func pure1 missing")
  assertTrue(not Str.contains(plain.repr, "@io"), "no @io on an ordinary function")
  val rt = parse("package P\n\n" + io.repr + " = 1\n")
  assertEqualInt(rt.diagnostics.count, 0, "the repr re-parses (got " + io.repr + ")")
}

// #7827 / D168: each default of a public callable is compiled into a thunk,
// and the contract renders the parameter's default as a call to it, so no
// default expression leaves the package.  A parameter whose type names a
// type parameter, and a private function, export none.
test "buildContractFromFile renders parameter defaults as calls to compiled thunks (#7827)" {
  val src = "package P\n\nval base: Int = 1\n\n" + "pub func f(x: in Int = base + 4, y: in Int): Int = x + y\n" +
    "pub func g[T](o: in Option[T] = None, n: in Int = 2): Int = n\n" +
    "func priv(z: in Int = 1): Int = z\n" +
    "pub record R {\n  n: Int\n  func m(self: in R, k: in Int = 3): Int {\n    k\n  }\n}\n" +
    "pub interface I {\n  func a(self: in Self, s: in Int = 2): Int\n}\n" +
    "pub record Q {\n  q: Int\n}\n" +
    "impl I for Q {\n  func a(self: in Q, s: in Int = 4): Int {\n    s\n  }\n}\n"
  val c = buildContractFromFile(synthesizeDefaultThunks(parse(src).file), "1.0.0")
  val f = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "f"), "func f missing")
  assertTrue(
    Str.contains(f.repr, "x: in Int = P.__lyric_default__f0_1_1_f2_r1_3_Intr1_3_Int1_x()"),
    "f's default is a thunk call: " + f.repr
  )
  assertTrue(not Str.contains(f.repr, "base"), "the default expression is not carried: " + f.repr)
  assertTrue(Str.contains(f.repr, "y: in Int)"), "y has no default: " + f.repr)
  assertTrue(
    isSomeDecl(findDeclByKind(c.decls, "func", "__lyric_default__f0_1_1_f2_r1_3_Intr1_3_Int1_x")),
    "the thunk is exported"
  )
  val g = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "g"), "func g missing")
  assertTrue(
    Str.contains(g.repr, "n: in Int = P.__lyric_default__f0_1_1_g2_g1_6_Option1_tr1_1_Tr1_3_Int1_n()"),
    "g's Int default: " + g.repr
  )
  assertTrue(Str.contains(g.repr, "o: in Option[T],"), "a T-typed default is not exported: " + g.repr)
  assertTrue(
    not isSomeDecl(findDeclByKind(c.decls, "func", "__lyric_default__f0_1_1_g2_g1_6_Option1_tr1_1_Tr1_3_Int1_o")),
    "no thunk for it"
  )
  assertTrue(
    not isSomeDecl(findDeclByKind(c.decls, "func", "__lyric_default__f0_1_4_priv1_r1_3_Int1_z")),
    "no thunk for a private function"
  )
  val r = unwrapDeclOrFail(findDeclByKind(c.decls, "record", "R"), "record R missing")
  assertTrue(
    Str.contains(r.repr, "k: in Int = P.__lyric_default__m1_1_R1_1_m2_r1_1_Rr1_3_Int1_k()"),
    "record method: " + r.repr
  )
  val i = unwrapDeclOrFail(findDeclByKind(c.decls, "interface", "I"), "interface I missing")
  assertTrue(
    Str.contains(i.repr, "s: in Int = P.__lyric_default__i1_1_I1_1_a2_er1_3_Int1_s()"),
    "interface member: " + i.repr
  )
  val q = unwrapDeclOrFail(findDeclByKind(c.decls, "impl", "Q"), "impl for Q missing")
  assertTrue(
    Str.contains(q.repr, "func a(self: in Q, s: in Int = P.__lyric_default__p2_1_Q1_I1_1_a2_r1_1_Qr1_3_Int1_s()): Int"),
    "the impl carries its method head: " + q.repr
  )
  val reparsed = parse("package P\n\n" + f.repr + "\n\n" + r.repr + "\n\n" + i.repr + "\n\n" + q.repr + "\n")
  assertEqualInt(reparsed.diagnostics.count, 0, "the reprs re-parse")
}

// Without defaults the impl repr stays bodyless.
test "an impl with no defaulted parameter keeps its empty repr (#7827)" {
  val src = "package P\n\npub interface I {\n  func a(self: in Self, s: in Int): Int\n}\n" +
    "pub record Q {\n  q: Int\n}\n" +
    "impl I for Q {\n  func a(self: in Q, s: in Int): Int {\n    s\n  }\n}\n"
  val c = buildContractFromFile(synthesizeDefaultThunks(parse(src).file), "1.0.0")
  val q = unwrapDeclOrFail(findDeclByKind(c.decls, "impl", "Q"), "impl for Q missing")
  assertEqual(q.repr, "impl I for Q {}", "unchanged repr")
}

// #8085: two overloads of one name and parameter count each get their own
// thunk, named from their parameter types, and the contract points each
// overload's parameter at its own.  (The type checker rejects such a pair,
// T0001 / T0162; the name keeps them apart regardless.)
test "same-count overloads render distinct default thunks (#8085)" {
  val src = "package P\n\npub record R {\n  n: Int\n" +
    "  func scale(self: in R, x: in Int, factor: in Int = 1): Int {\n    x * factor\n  }\n" +
    "  func scale(self: in R, x: in String, factor: in Int = 2): Int {\n    factor\n  }\n}\n"
  val c = buildContractFromFile(synthesizeDefaultThunks(parse(src).file), "1.0.0")
  val r = unwrapDeclOrFail(findDeclByKind(c.decls, "record", "R"), "record R missing")
  assertTrue(
    Str.contains(
      r.repr,
      "x: in Int, factor: in Int = P.__lyric_default__m1_1_R1_5_scale3_r1_1_Rr1_3_Intr1_3_Int6_factor()"
    ),
    "the Int overload's own thunk: " + r.repr
  )
  assertTrue(
    Str.contains(
      r.repr,
      "x: in String, factor: in Int = P.__lyric_default__m1_1_R1_5_scale3_r1_1_Rr1_6_Stringr1_3_Int6_factor()"
    ),
    "the String overload's own thunk: " + r.repr
  )
  assertTrue(
    isSomeDecl(findDeclByKind(c.decls, "func", "__lyric_default__m1_1_R1_5_scale3_r1_1_Rr1_3_Intr1_3_Int6_factor")),
    "first thunk"
  )
  assertTrue(
    isSomeDecl(findDeclByKind(c.decls, "func", "__lyric_default__m1_1_R1_5_scale3_r1_1_Rr1_6_Stringr1_3_Int6_factor")),
    "second thunk"
  )
}

// The name spells every type form as identifier text, each part length- or
// count-prefixed (#8085, #8097).
test "defaultThunkName spells every type form as identifier text (#8097)" {
  val pr = parse(
    "package P\n\nfunc k(a: in List[Int], b: in slice[String], c: in (Int, Bool), d: in (Int) -> Std.Core.Unit, e: in Int?): Unit {}\n"
  )
  val none: List[String] = newList()
  match pr.file.items[0].kind {
    case IFunc(fn) -> assertEqual(
      defaultThunkName(DTFunction, none, "k", fn.params, "e"),
      "__lyric_default__f0_1_1_k5_g1_4_List1_tr1_3_Intsr1_6_Stringt2_r1_3_Intr1_4_Boolc1_r1_3_Intr3_3_Std4_Core4_Unitor1_3_Int1_e",
      "name"
    )
    case _ -> assertTrue(false, "a function")
  }
}

// #8097: the encoding is injective across kinds and owner/callable splits:
// the same owner, name, parameters and parameter give a different name for
// a function, a record method, an interface member and an impl method, and
// `Acc` + `scaled` never meets `Acc.scaled` or `Acc__scaled`.
test "defaultThunkName distinguishes every kind and owner split (#8097)" {
  val pr = parse("package P\n\nfunc k(self: in Acc, k: in Int = 1): Int = k\n")
  match pr.file.items[0].kind {
    case IFunc(fn) -> {
      val none: List[String] = newList()
      val acc: List[String] = newList()
      acc.add("Acc")
      val accI: List[String] = newList()
      accI.add("Acc")
      accI.add("I")
      val accU: List[String] = newList()
      accU.add("Acc__")
      val names: List[String] = newList()
      names.add(defaultThunkName(DTFunction, none, "Acc.scaled", fn.params, "k"))
      names.add(defaultThunkName(DTFunction, none, "Acc__scaled", fn.params, "k"))
      names.add(defaultThunkName(DTRecordMethod, acc, "scaled", fn.params, "k"))
      names.add(defaultThunkName(DTRecordMethod, accU, "scaled", fn.params, "k"))
      names.add(defaultThunkName(DTInterfaceMember, acc, "scaled", fn.params, "k"))
      names.add(defaultThunkName(DTImplMethod, accI, "scaled", fn.params, "k"))
      var i = 0
      while i < names.count {
        var j = i + 1
        while j < names.count {
          assertTrue(names[i] != names[j], "distinct: " + names[i] + " / " + names[j])
          j = j + 1
        }
        i = i + 1
      }
    }
    case _ -> assertTrue(false, "a function")
  }
}

// #8097: a record method and a dot-named function of the same type, name
// and parameters each render their own default's thunk, and a parameter
// with no default renders none, even when the other callable's parameter
// of that name has one.
test "a record method and a same-named dot-named function keep their own defaults (#8097)" {
  val both = "package P\n\npub record Acc {\n  n: Int\n  func scaled(self: in Acc, k: in Int = 3): Int {\n    self.n * k\n  }\n}\n\n" +
    "pub func Acc.scaled(self: in Acc, k: in Int = 5): Int {\n  self.n + k\n}\n"
  val c = buildContractFromFile(synthesizeDefaultThunks(parse(both).file), "1.0.0")
  val r = unwrapDeclOrFail(findDeclByKind(c.decls, "record", "Acc"), "record Acc missing")
  assertTrue(
    Str.contains(r.repr, "k: in Int = P.__lyric_default__m1_3_Acc1_6_scaled2_r1_3_Accr1_3_Int1_k()"),
    "the method's own thunk: " + r.repr
  )
  val f = unwrapDeclOrFail(findDeclByKind(c.decls, "func", "Acc.scaled"), "func Acc.scaled missing")
  assertTrue(
    Str.contains(f.repr, "k: in Int = P.__lyric_default__f0_2_3_Acc6_scaled2_r1_3_Accr1_3_Int1_k()"),
    "the function's own thunk: " + f.repr
  )
  val oneSided = "package P\n\npub record Acc {\n  n: Int\n  func scaled(self: in Acc, k: in Int = 3): Int {\n    self.n * k\n  }\n}\n\n" +
    "pub func Acc.scaled(self: in Acc, k: in Int): Int {\n  self.n + k\n}\n"
  val c2 = buildContractFromFile(synthesizeDefaultThunks(parse(oneSided).file), "1.0.0")
  val f2 = unwrapDeclOrFail(findDeclByKind(c2.decls, "func", "Acc.scaled"), "func Acc.scaled missing")
  assertTrue(not Str.contains(f2.repr, "="), "no default rendered for a parameter that has none: " + f2.repr)
  val r2 = unwrapDeclOrFail(findDeclByKind(c2.decls, "record", "Acc"), "record Acc missing")
  assertTrue(
    Str.contains(r2.repr, "k: in Int = P.__lyric_default__m1_3_Acc"),
    "the method keeps its default: " + r2.repr
  )
}
