//! subscript_assign_jvm_self_test.l — CI gate for the JVM `Map[K, V]`/`List[T]`
//! subscript (`m[k]`, `m[k] = v`, `m[k] += v`) codegen gap discovered while
//! re-verifying docs/44 m-5 (#1707).
//!
//! Two independent bugs in `Jvm.Codegen`'s `EIndex` lowering, both in the same
//! assignment-target function (`lowerAssignExpr`, `codegen/05_stmts.l`):
//!
//!   1. **Map subscript always misrouted to List codegen (crash).** Neither the
//!      read side (`02_exprs.l`) nor the write side (`05_stmts.l`) had a case
//!      for a `HashMap` receiver — every non-array, non-`String` receiver fell
//!      through to `ArrayList.get(int)` / `ArrayList.set(int, Object)`. A `Map`
//!      subscript pushed its (typically `String`) key where an `int` index was
//!      expected, so `m[k]` / `m[k] = v` failed `VerifyError: Bad type on
//!      operand stack` at class-load time — not a silent miscompile, but a
//!      crash on every Map subscript use.  Fixed by adding a `HashMap` branch to
//!      both the read and write sides, boxing the key like any Object-erased
//!      argument (`java.util.HashMap.get`/`.put`).
//!
//!   2. **Compound-assignment (`+=`, `-=`, `*=`, `/=`, `%=`) through a List or
//!      Map subscript silently dropped the operator — a genuine SILENT
//!      MISCOMPILE, worse than a crash.** The pre-fix write-side `case _ ->`
//!      arm always lowered `value` as the literal new element and called
//!      `ArrayList.set`, regardless of `op` — `lst[i] += 5` therefore SET
//!      `lst[i]` to `5` instead of incrementing it, with no error at build or
//!      run time.  Fixed by mirroring the pre-existing `JArray` compound-assign
//!      pattern: load `[list/map, index/key]` TWICE (so the pair survives under
//!      the fetched/combined value with no reordering), `get` the current
//!      value, unbox it to the RHS's concrete type via `emitUnboxObjectTo`
//!      (reused from the #4877 erased-payload work), combine via the existing
//!      `emitCompoundArith`, box the result, and `set`/`put` back.
//!
//! Run via the native test runner on BOTH targets (MSIL already reifies List/
//! Map's real element/value types and was never affected — this file locks in
//! parity):
//!
//!   lyric test --target dotnet lyric-compiler/jvm/subscript_assign_jvm_self_test.l
//!   lyric test --target jvm    lyric-compiler/jvm/subscript_assign_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Jvm.SubscriptAssignJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// The original #1707/m-5 repro shape: a Map[String,_] lookup feeding a nested
// generic union construction (`Ok(Some(...))` / `Ok(None)`).
func lookupF(data: in Map[String, String], id: in String): Result[Option[String], String] {
  if data.containsKey(id) {
    Ok(Some(value = data[id]))
  } else {
    Ok(None)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. Map[String, V] subscript read / write — the crash repro.
// ─────────────────────────────────────────────────────────────────────────────
test "map subscript write then read round-trips (Int value)" {
  val m: Map[String, Int] = newMap()
  m["a"] = 10
  assertEqualInt(m["a"], 10, "map subscript write/read round-trips")
}

test "map subscript overwrite replaces the value" {
  val m: Map[String, String] = newMap()
  m["x"] = "first"
  m["x"] = "second"
  assertEqual(m["x"], "second", "overwrite replaces value")
}

test "map subscript with Long values round-trips (two-slot width)" {
  val m: Map[String, Long] = newMap()
  m["big"] = 1000000000i64
  assertEqualLong(m["big"], 1000000000i64, "long map value round-trips")
}

test "nested-generic Map lookup feeding Ok(Some)/Ok(None) construction (#1707)" {
  val store: Map[String, String] = newMap()
  store["k"] = "v"
  val hit = lookupF(store, "k")
  val miss = lookupF(store, "absent")
  match hit {
    case Ok(opt) -> match opt { case Some(v) -> assertEqual(v, "v", "present key yields Ok(Some(value))"); case None -> assertTrue(false, "present key must not yield None") }
    case Err(_) -> assertTrue(false, "must not be Err")
  }
  match miss {
    case Ok(opt) -> match opt { case Some(_) -> assertTrue(false, "absent key must not yield Some"); case None -> assertTrue(true, "absent key yields Ok(None)") }
    case Err(_) -> assertTrue(false, "must not be Err")
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. Map[String, V] compound-assignment (`+=` etc.) — the silent-miscompile
//    repro. Pre-fix this silently set the value to the RHS, dropping the
//    current value entirely.
// ─────────────────────────────────────────────────────────────────────────────
test "map subscript compound-assign adds to the current value (Int)" {
  val m: Map[String, Int] = newMap()
  m["k"] = 10
  m["k"] += 5
  assertEqualInt(m["k"], 15, "10 += 5 must be 15, not 5 (silent-miscompile regression)")
}

test "map subscript compound-assign on Long values (two-slot width)" {
  val m: Map[String, Long] = newMap()
  m["big"] = 1000000000i64
  m["big"] += 500000000i64
  assertEqualLong(m["big"], 1500000000i64, "long compound-assign through map")
}

test "map subscript compound-assign supports -, *, /" {
  val m: Map[String, Int] = newMap()
  m["v"] = 20
  m["v"] -= 5
  assertEqualInt(m["v"], 15, "20 -= 5 == 15")
  m["v"] *= 2
  assertEqualInt(m["v"], 30, "15 *= 2 == 30")
  m["v"] /= 3
  assertEqualInt(m["v"], 10, "30 /= 3 == 10")
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. List[T] subscript read / write (unaffected by bug 1, sanity-checked here
//    for parity) and compound-assignment (bug 2 also affected List targets).
// ─────────────────────────────────────────────────────────────────────────────
test "list subscript write then read round-trips (String)" {
  val lst: List[String] = newList()
  lst.add("a")
  lst[0] = "z"
  assertEqual(lst[0], "z", "list subscript write/read round-trips")
}

test "list subscript compound-assign adds to the current value" {
  val lst: List[Int] = newList()
  lst.add(10)
  lst[0] += 5
  assertEqualInt(lst[0], 15, "10 += 5 must be 15, not 5 (silent-miscompile regression)")
}

test "list subscript compound-assign on Double values" {
  val lst: List[Double] = newList()
  lst.add(2.5)
  lst[0] += 1.5
  assertTrue(lst[0] == 4.0, "2.5 += 1.5 == 4.0")
}
