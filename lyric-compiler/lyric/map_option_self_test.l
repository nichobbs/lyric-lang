//! #1727 (codegen slice): `mapGet(m, key)` now lowers to a real `Option[V]`
//! (`m.ContainsKey(key) ? Some(value = m[key]) : None`) with the concrete `V`
//! from the call's context hint, and `Map.remove(key)` calls the real
//! `Dictionary.Remove` instead of the former pop-only stub.  Together these
//! closed the `lyric-session` store suite (24/31 -> 31/31): its `get()` is
//! `Ok(mapGet(data.entries, key))` and `delete()` / `destroy()` mutate via
//! `.remove(...)`.
//!
//! Also pins #5003 (JVM): `Ok(mapGet(...))` — a branching intrinsic call
//! nested directly as a union-case constructor argument — used to
//! `VerifyError` ("Inconsistent stackmap frames") on `--target jvm`.
//! `lowerConstruction` (`codegen/04_calls.l`) previously emitted `new; dup`
//! for the outer `Ok`/`Some` BEFORE lowering its argument, so `mapGet`'s
//! internal `containsKey`-gated branch executed with the outer constructor's
//! two uninitialized-object stack slots still present underneath — its own
//! StackMapTable (correctly computed assuming an empty stack) then disagreed
//! with the actual runtime stack shape.  Fixed by evaluating every
//! constructor argument into a local BEFORE `new; dup`, so any argument's
//! internal branches always start from an empty stack regardless of the
//! enclosing constructor call.
//!
//! Run on BOTH targets in CI (`compiler-self-tests-dotnet-b` /
//! `compiler-self-tests-jvm` — MSIL was never affected, this file locks in
//! parity).
//!
//! Also pins #6835/#6120 (both targets): `==`/`!=` structural equality on
//! `Option[T]` (a generic union, the CI size ceiling — #6781 — steered this
//! into the nearest already dual-target-wired `Option`-themed file rather
//! than a new one). See the tests just after `makeOptional`'s for the
//! `None == None` / independently-constructed-equal-`Some` cases.
@test_module
package Lyric.MapOptionSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func tag(o: in Option[String]): Int {
  match o {
    case None -> 0
    case Some(_) -> 1
  }
}

test "mapGet hit returns Some, miss returns None" {
  val m: Map[String, String] = newMap()
  m["k"] = "v"
  assertEqualInt(tag(mapGet(m, "k")), 1, "present -> Some")
  assertEqualInt(tag(mapGet(m, "absent")), 0, "missing -> None")
}

test "mapGet Some round-trips the value" {
  val m: Map[String, String] = newMap()
  m["greeting"] = "hello"
  match mapGet(m, "greeting") {
    case None -> assertTrue(false, "should be Some")
    case Some(v) -> assertEqual(v, "hello", "payload preserved")
  }
}

func tagInt(o: in Option[Int]): Int {
  match o {
    case None -> -1
    case Some(n) -> n
  }
}

test "mapGet on a value-type payload (Map[String, Int]) unbox.any-s correctly" {
  val m: Map[String, Int] = newMap()
  m["n"] = 42
  assertEqualInt(tagInt(mapGet(m, "n")), 42, "present Int -> Some(42)")
  assertEqualInt(tagInt(mapGet(m, "absent")), -1, "missing Int -> None")
}

test "Map.remove actually removes the key (mapGet None afterwards)" {
  val m: Map[String, String] = newMap()
  m["k"] = "v"
  assertTrue(m.containsKey("k"), "present before remove")
  val _ = m.remove("k")
  assertTrue(not m.containsKey("k"), "absent after remove")
  assertEqualInt(tag(mapGet(m, "k")), 0, "mapGet None after remove")
}

// The exact lyric-session shape: a record field holding the Map, read inside an
// impl method, with `mapGet` wrapped in `Ok(...)` (so the context hint for `V`
// arrives through the `Result`/`Ok` payload), plus a `.remove`-based delete.
record Store {
  var entries: Map[String, String]
}

interface KV {
  func get(s: in Store, k: in String): Result[Option[String], String]
  func del(s: in Store, k: in String): Result[Unit, String]
}

record KVImpl {
}

impl KV for KVImpl {
  func get(s: in Store, k: in String): Result[Option[String], String] {
    Ok(mapGet(s.entries, k))
  }
  func del(s: in Store, k: in String): Result[Unit, String] {
    val _ = s.entries.remove(k)
    Ok(())
  }
}

test "impl get() wraps mapGet in Ok(Option[String]); del() removes" {
  val s = Store(entries = newMap())
  s.entries["a"] = "av"
  val kv: KV = KVImpl()
  match kv.get(s, "a") {
    case Err(_) -> assertTrue(false, "get should be Ok")
    case Ok(opt) -> match opt {
      case None -> assertTrue(false, "a should be present")
      case Some(v) -> assertEqual(v, "av", "get a -> av")
    }
  }
  match kv.del(s, "a") {
    case Err(_) -> assertTrue(false, "del should be Ok")
    case Ok(_) -> ()
  }
  match kv.get(s, "a") {
    case Err(_) -> assertTrue(false, "get should be Ok")
    case Ok(opt) -> match opt {
      case None -> assertTrue(true, "a removed -> None")
      case Some(_) -> assertTrue(false, "a should be gone after del")
    }
  }
}

// A general (non-`mapGet`-specific) #5003 repro: an `if` EXPRESSION whose two
// branches construct DIFFERENT union cases (`Some`/`None`), used directly as
// a constructor argument to the outer `Ok(...)`.  Exercises the same
// new-then-branch stack-shape hazard `lowerConstruction`'s fix addresses,
// without going through the `mapGet` intrinsic at all.
func makeOptional(present: in Bool, v: in String): Result[Option[String], String] {
  Ok(if present { Some(value = v) } else { None })
}

test "if-expression constructing different union cases as a nested constructor argument (#5003)" {
  match makeOptional(true, "hi") {
    case Err(_) -> assertTrue(false, "should be Ok")
    case Ok(opt) -> match opt {
      case None -> assertTrue(false, "should be Some")
      case Some(v) -> assertEqual(v, "hi", "present branch")
    }
  }
  match makeOptional(false, "hi") {
    case Err(_) -> assertTrue(false, "should be Ok")
    case Ok(opt) -> match opt {
      case None -> assertTrue(true, "absent branch")
      case Some(_) -> assertTrue(false, "should be None")
    }
  }
}

// #6835/#6120: `==`/`!=` on `Option[T]` must be genuinely structural, not
// reference/tag identity.  Before the fix every union case class (generic or
// not) had no `Equals`/`equals` override at all, so `BEq`/`BNeq` fell back to
// bare `Object.Equals`/reference-identity dispatch: a GENERIC nullary case
// has no singleton (docs/43 Q-GEN-001 — freshly `newobj`'d on every
// construction), so `None == None` was false, and every `== None` /
// `!= None` comparison came out wrong the same way; two independently-
// constructed equal-payload `Some` values also compared unequal (#6120).
// `Msil.Codegen.buildUnionCaseEqualityOverridesMsil` (MSIL) and
// `Jvm.Lowering.buildUnionCaseEqualsFunc`/`buildUnionCaseHashCodeFunc` (JVM)
// now give every union case class a real structural override, unconditionally
// (unions have structural equality by default, language reference §2.4) —
// verified here on both targets via this file's existing CI wiring.
@derive(Equals)
record EqPair {
  a: Int
  b: Int
}

func noneInt(): Option[Int] {
  None
}

func someInt(n: Int): Option[Int] {
  Some(value = n)
}

test "#6835: None == None is true for independently-constructed generic nullary cases" {
  assertTrue(noneInt() == noneInt(), "None == None")
  assertTrue(not (noneInt() != noneInt()), "!(None != None)")
}

test "#6835: Some(x) == None and None == Some(x) are false" {
  assertTrue(not (someInt(5) == noneInt()), "Some(5) == None is false")
  assertTrue(someInt(5) != noneInt(), "Some(5) != None is true")
  assertTrue(not (noneInt() == someInt(5)), "None == Some(5) is false")
  assertTrue(noneInt() != someInt(5), "None != Some(5) is true")
}

test "#6120: two independently-constructed equal-payload Some[Int] values compare == true" {
  val a = someInt(1)
  val b = someInt(1)
  assertTrue(a == b, "Some(1) == Some(1) (independently constructed)")
  assertTrue(not (a != b), "!(Some(1) != Some(1))")
  val c = someInt(2)
  assertTrue(not (a == c), "Some(1) == Some(2) is false")
  assertTrue(a != c, "Some(1) != Some(2) is true")
}

func someStr(s: in String): Option[String] {
  Some(value = s)
}

test "#6120: Some holding an independently-built String payload compares structurally" {
  // "al" + "ice" forces a genuinely distinct String object at runtime (not
  // the same interned literal as "alice") so this cannot pass by accidental
  // reference equality — it must go through String's own structural equals.
  val a = someStr("al" + "ice")
  val b = someStr("alice")
  assertTrue(a == b, "Some(\"alice\") == Some(\"alice\") built via concatenation")
  assertTrue(not (a != b), "!(Some(\"alice\") != Some(\"alice\"))")
}

func somePair(x: Int, y: Int): Option[EqPair] {
  Some(value = EqPair(a = x, b = y))
}

test "#6120: Some holding an independently-constructed record payload compares structurally" {
  val a = somePair(3, 4)
  val b = somePair(3, 4)
  assertTrue(a == b, "Some(EqPair(3,4)) == Some(EqPair(3,4)) (independently constructed)")
  val c = somePair(3, 9)
  assertTrue(not (a == c), "Some(EqPair(3,4)) == Some(EqPair(3,9)) is false")
  assertTrue(a != c, "Some(EqPair(3,4)) != Some(EqPair(3,9)) is true")
}
