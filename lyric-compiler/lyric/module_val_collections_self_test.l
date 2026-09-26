//! Module-level `val`s holding concrete collections, on both targets.
//!
//! On MSIL a `val m: Map[String, Bool] = newMap()` at module level built a
//! `Dictionary<object, object>`, and the first read, which expects the
//! annotated `Dictionary<string, bool>`, failed with InvalidCastException.
//! A module-level `val` of a record or protected type whose field defaults
//! to `newMap()` failed codegen outright, because the TypeDef discovery pass
//! lowered the `.cctor` body in a context with no BCL TypeRefs.
@test_module
package ModuleValCollectionsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val flags: Map[String, Bool] = newMap()

val names: List[String] = newList()

record Registry {
  var entries: Map[String, Int] = newMap()
}

val registry: Registry = Registry()

protected type Ledger {
  var inFlight: Map[String, Bool] = newMap()
  entry claim(key: in String): Bool {
    if inFlight.containsKey(key) {
      return false
    }
    inFlight[key] = true
    true
  }
  entry release(key: in String): Unit {
    inFlight.remove(key)
  }
}

val ledger: Ledger = Ledger()

test "a module-level Map val keeps its annotated type" {
  flags["on"] = true
  assertTrue(flags.containsKey("on"), "the key is present")
  assertTrue(flags["on"], "the value reads back as a Bool")
}

test "a module-level List val keeps its annotated type" {
  names.add("a")
  names.add("b")
  assertEqualInt(names.count, 2, "both elements are present")
  assertEqual(names[1], "b", "elements read back as String")
}

test "a module-level record with a Map field default" {
  registry.entries["x"] = 7
  assertEqualInt(registry.entries["x"], 7, "the record's map holds Int values")
}

test "a module-level protected type with a Map field" {
  assertTrue(ledger.claim("k"), "first claim succeeds")
  assertTrue(not ledger.claim("k"), "second claim is refused")
  ledger.release("k")
  assertTrue(ledger.claim("k"), "claim succeeds again after release")
}
