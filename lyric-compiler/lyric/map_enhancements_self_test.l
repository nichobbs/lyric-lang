//! map_enhancements_self_test.l — Map helpers from Std.Collections.
//!
//! Tests for mapSize and mapIsEmpty helper functions. Both are currently
//! tested on dotnet target; JVM parity testing is tracked in #3577.
//! Marked non-@stable pending JVM validation per CLAUDE.md production-readiness
//! standard (forbids undocumented one-platform implementations).
//!
//! Iteration functions (mapKeys, mapValues, mapEntries, mapForEach, mapPutAll)
//! and the MapEntry record are deferred to a follow-up PR, pending resolution
//! of codegen epics #3511 (IEnumerator protocol) and #3512 (generic stdlib
//! record construction). See issue #3442.
//!
//! Run in CI via native `lyric test --target dotnet`.  Imports only `Std.*`.
@test_module
package Lyric.MapEnhancementsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

test "mapSize returns zero for empty map" {
  val m: Map[String, Int] = newMap()
  assertEqualInt(mapSize(m), 0, "empty map size is 0")
}

test "mapSize returns correct count after additions" {
  val m: Map[String, Int] = newMap()
  m["a"] = 1
  m["b"] = 2
  m["c"] = 3
  assertEqualInt(mapSize(m), 3, "map with 3 entries size is 3")
}

test "mapSize decreases after removal" {
  val m: Map[String, Int] = newMap()
  m["a"] = 1
  m["b"] = 2
  assertEqualInt(mapSize(m), 2, "map size is 2 before removal")
  val _ = m.remove("a")
  assertEqualInt(mapSize(m), 1, "map size is 1 after removing one entry")
}

test "mapSize unchanged when overwriting existing key" {
  val m: Map[String, Int] = newMap()
  m["key"] = 1
  assertEqualInt(mapSize(m), 1, "initial size is 1")
  m["key"] = 2
  assertEqualInt(mapSize(m), 1, "size remains 1 after overwrite")
}

test "mapIsEmpty returns true for empty map" {
  val m: Map[String, Int] = newMap()
  assertTrue(mapIsEmpty(m), "empty map is empty")
}

test "mapIsEmpty returns false for non-empty map" {
  val m: Map[String, Int] = newMap()
  m["key"] = 42
  assertTrue(not mapIsEmpty(m), "map with entries is not empty")
}
