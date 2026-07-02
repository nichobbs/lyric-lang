//! map_iteration_jvm_self_test.l — Std.Collections Map iteration helpers on
//! `--target jvm` (#3676, epic #2663 band J6).
//!
//! `mapKeys` / `mapValues` / `mapEntries` / `mapForEach` / `mapPutAll` depend
//! on the kernel's `dictGetKeys` / `dictGetValues` collection views.  The JVM
//! kernel (`_kernel_jvm/collections_host.l`) previously ended before those
//! declarations (and routed `tryGetValue` / `setToSlice` through a
//! `lyric.stdlib.jvm.*` shim class that never existed), so JVM builds of any
//! program touching the iteration helpers failed with unresolved types.  The
//! kernel now binds the views to `HashMap.keySet()` (java.util.Set) and
//! `.values()` (java.util.Collection) via the auto-FFI, both iterated through
//! the emitter's Iterable path; `tryGetValue` and `setToSlice` are plain
//! Lyric bodies over `containsKey`/`get` and `HashSet.toArray()`.
//!
//! `mapForEach` is not exercised here: a two-parameter lambda literal
//! (`(k, v) -> ...`) does not yet parse in call-argument position (the
//! self-hosted parser reads the parenthesised parameter list as a tuple
//! expression), so its coverage waits on that parser gap.  Element
//! consumption in the mapValues/mapEntries cases is count-shaped: iterated
//! elements are erased to Object on JVM, so element arithmetic and entry
//! field access wait on the typed-erasure work in band J4 (#2667).
//! Value-level semantics are covered via mapGet / mapPutAll, whose results
//! carry concrete types after monomorphization (#3229).
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`.  Imports only `Std.*`.
@test_module
package Jvm.MapIterationSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func sampleMap(): Map[String, Int] {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  m.add("c", 3)
  m
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "mapGet distinguishes present and absent keys" {
  val m = sampleMap()
  match mapGet(m, "b") {
    case Some(v) -> assertEqualInt(v, 2, "mapGet present key")
    case None -> assertTrue(false, "'b' must be present")
  }
  match mapGet(m, "zz") {
    case Some(_) -> assertTrue(false, "'zz' must be absent")
    case None -> assertTrue(true, "mapGet absent key")
  }
}

test "mapKeys iterates every key" {
  val m = sampleMap()
  var seen = 0
  var sawB = false
  for k in mapKeys(m) {
    seen = seen + 1
    if k == "b" {
      sawB = true
    }
  }
  assertEqualInt(seen, 3, "three keys iterated")
  assertTrue(sawB, "key 'b' seen")
}

// Element consumption is count-shaped for mapValues/mapEntries: iterated
// elements are erased to Object on JVM, so arithmetic on a value element
// (`total + v`) and field access on an entry element (`e.value`) need the
// typed-erasure work tracked under band J4 (#2667).  Value-level semantics
// are exercised through mapGet and mapPutAll below, whose results carry
// concrete types.
test "mapValues iterates every value" {
  val m = sampleMap()
  var seen = 0
  for v in mapValues(m) {
    seen = seen + 1
  }
  assertEqualInt(seen, 3, "three values iterated")
}

test "mapEntries yields every key/value pair" {
  val m = sampleMap()
  val entries = mapEntries(m)
  assertEqualInt(entries.count, 3, "three entries")
}

test "mapPutAll copies and overwrites" {
  val dst = sampleMap()
  val src: Map[String, Int] = newMap()
  src.add("b", 20)
  src.add("d", 4)
  mapPutAll(dst, src)
  assertEqualInt(mapSize(dst), 4, "dst has 4 entries after putAll")
  match mapGet(dst, "b") {
    case Some(v) -> assertEqualInt(v, 20, "existing key overwritten")
    case None -> assertTrue(false, "'b' must remain present")
  }
  match mapGet(dst, "d") {
    case Some(v) -> assertEqualInt(v, 4, "new key copied")
    case None -> assertTrue(false, "'d' must be copied in")
  }
}
