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
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Lyric.ContractMeta
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
        formatVersion = 0,
        decls = newList(),
        dependencies = newList(),
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
      params = params
    )
  )
  val original = Contract(
    packageName = "RoundTrip.Pkg",
    version = "1.2.3",
    level = "runtime_checked",
    formatVersion = 2,
    decls = decls,
    dependencies = newList(),
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
      params = noParams
    )
  )
  val c = Contract(
    packageName = "Geom",
    version = "0.1.0",
    level = "runtime_checked",
    formatVersion = 2,
    decls = decls,
    dependencies = newList(),
    contractHash = ""
  )
  val json = contractToJson(c)
  assertTrue(not Str.contains(json, "\"stability\""), "omits_defaults: empty stability key absent")
  assertTrue(not Str.contains(json, "\"pure\""), "omits_defaults: false pure key absent")
  assertTrue(not Str.contains(json, "\"requires\""), "omits_defaults: empty requires absent")
  assertTrue(not Str.contains(json, "\"ensures\""), "omits_defaults: empty ensures absent")
  assertTrue(not Str.contains(json, "\"body\""), "omits_defaults: None body absent")
  assertTrue(not Str.contains(json, "\"params\""), "omits_defaults: empty params absent")
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
        params = newList()
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

test "buildContractFromFile union mixed fields" {
  testBuildUnionMixedFields()
}

test "buildContractFromFile array type arg" {
  testBuildArrayTypeArg()
}

test "buildContractFromFile version threaded" {
  testBuildVersionThreaded()
}

test "buildContractFromFile filters non-pub" {
  testBuildFiltersNonPub()
}
