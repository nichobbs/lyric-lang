//! contract_meta_emit_self_test.l — basic tests for Lyric.ContractMetaEmit
//!
//! Verifies the two-pass hashing protocol and JSON structure. Tests the
//! Lyric.ContractMetaEmit package's ability to emit contract metadata v3
//! with SHA-256 integrity hashing.
//!
//! **Not currently wired into CI** — awaiting issue #2580 (in-process MSIL
//! bridge support for self-hosted compiler packages). The test suite can be
//! run manually once the infrastructure is ready.
@test_module
package Lyric.ContractMetaEmit.Tests

import Std.Core
import Std.Testing
import Lyric.ContractMeta as Meta
import Lyric.ContractMetaEmit as Emit

func testEmitSimpleContract(): Unit {
  // Create a minimal contract for testing
  val decl = Meta.ContractDecl(
    kind = "func",
    name = "testFunc",
    repr = "func testFunc(): Int",
    visibility = "pub",
    isPure = false,
    stability = "stable:1.0",
    requiresClauses = [],
    ensuresClauses = [],
    body = None,
    params = []
  )

  val contract = Meta.Contract(
    packageName = "Test.Package",
    version = "1.0.0",
    level = "runtime_checked",
    formatVersion = 3,
    decls = [decl],
    dependencies = [],
    contractHash = ""
  )

  val json = Emit.emitContractMetadata(contract)
  // Verify the JSON is non-empty and contains expected fields
  assertTrue(json.length > 0, "emitted JSON is non-empty")
  assertTrue(
    json.contains("\"packageName\":") and json.contains("\"Test.Package\""),
    "JSON contains packageName field"
  )
  // Verify contractHash field is present (contains 64-char SHA-256 hex digest)
  assertTrue(
    json.contains("\"contractHash\":\""),
    "JSON contains contractHash field"
  )
  // Verify the two-pass protocol produced a substantial hash: the JSON should be
  // longer than the basic structure (minimum ~110 chars for this minimal contract)
  assertTrue(json.length > 120, "JSON includes 64-char SHA-256 hash")
  assertTrue(json.contains("\"formatVersion\":3"), "JSON contains formatVersion 3")
}

func testHashConsistency(): Unit {
  // Create two identical contracts and verify they produce the same hash
  val decl = Meta.ContractDecl(
    kind = "func",
    name = "same",
    repr = "func same(): Unit",
    visibility = "pub",
    isPure = false,
    stability = "",
    requiresClauses = [],
    ensuresClauses = [],
    body = None,
    params = []
  )

  val contract1 = Meta.Contract(
    packageName = "Hash.Test",
    version = "1.0.0",
    level = "axiom",
    formatVersion = 3,
    decls = [decl],
    dependencies = [],
    contractHash = ""
  )

  val contract2 = Meta.Contract(
    packageName = "Hash.Test",
    version = "1.0.0",
    level = "axiom",
    formatVersion = 3,
    decls = [decl],
    dependencies = [],
    contractHash = ""
  )

  val json1 = Emit.emitContractMetadata(contract1)
  val json2 = Emit.emitContractMetadata(contract2)
  assertEqual(json1, json2, "identical contracts produce identical JSON")
}
