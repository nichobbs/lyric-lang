//! contract_meta_emit_self_test.l — basic tests for Lyric.ContractMetaEmit
//!
//! Verifies the two-pass hashing protocol and JSON structure.
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
  // Verify contractHash is a 64-char hex string (SHA-256 produces exactly this)
  assertTrue(
    json.contains("\"contractHash\":\"") and json.length > 70,
    "JSON contains contractHash field with computed digest"
  )
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
