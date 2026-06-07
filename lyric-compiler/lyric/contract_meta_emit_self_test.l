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

  match Emit.emitContractMetadata(contract) {
    case Ok(json) -> {
      // Verify the JSON is non-empty and contains expected fields
      assertTrue(json.length > 0, "emitted JSON is non-empty")
      assertTrue(
        json.contains("\"packageName\":") and json.contains("\"Test.Package\""),
        "JSON contains packageName field"
      )
      assertTrue(
        json.contains("\"contractHash\":") and json.contains("E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855"),
        "JSON contains correct SHA-256 hash (empty string hash for initial contract)"
      )
      assertTrue(json.contains("\"formatVersion\":3"), "JSON contains formatVersion 3")
    }
    case Err(e) -> assertTrue(false, "emission should succeed")
  }
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

  match (Emit.emitContractMetadata(contract1), Emit.emitContractMetadata(contract2)) {
    case (Ok(json1), Ok(json2)) -> {
      assertEqual(json1, json2, "identical contracts produce identical JSON")
    }
    case _ -> assertTrue(false, "both emissions should succeed")
  }
}

func main(): Int {
  testEmitSimpleContract()
  testHashConsistency()
  println("contract_meta_emit tests: ok")
  return 0
}
