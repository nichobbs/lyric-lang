// #1687 regression: self-hosted MSIL mis-instantiated nested `Ok(None)` (D-progress-354).

@test_module
package Lyric.NestedGenericSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// Error payload for the outer Result's Err arm (mirrors lyric-session's shape).
record NErr { code: String }

// Tag which arm fired (0=Err, 1=Ok/None, 2=Ok/Some) without reading the payload.
func classify(r: in Result[Option[String], NErr]): Int {
  match r {
    case Err(_)  -> 0
    case Ok(opt) -> match opt {
      case None    -> 1
      case Some(_) -> 2
    }
  }
}

// Recover the inner String when the value is `Ok(Some(...))`, else a sentinel.
func innerOf(r: in Result[Option[String], NErr], sentinel: in String): String {
  match r {
    case Err(_)  -> sentinel
    case Ok(opt) -> match opt {
      case None    -> sentinel
      case Some(v) -> v
    }
  }
}

// The exact issue-repro shape: Ok(None)/Ok(Some) from a Map[String,_] lookup.
func lookupF(data: in Map[String, String], id: in String): Result[Option[String], NErr] {
  if data.containsKey(id) {
    Ok(Some(value = data[id]))
  } else {
    Ok(None)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Construction + match correctness for Result[Option[T], E]
// ─────────────────────────────────────────────────────────────────────────────

test "Ok(None) matches the Ok arm then the None arm" {
  val r: Result[Option[String], NErr] = Ok(None)
  assertEqualInt(classify(r), 1, "Ok(None) classifies as Ok->None")
}

test "Ok(Some(v)) matches the Ok arm then the Some arm" {
  val r: Result[Option[String], NErr] = Ok(Some(value = "hi"))
  assertEqualInt(classify(r), 2, "Ok(Some) classifies as Ok->Some")
}

test "Err(e) matches the Err arm" {
  val r: Result[Option[String], NErr] = Err(NErr(code = "BOOM"))
  assertEqualInt(classify(r), 0, "Err classifies as Err")
}

test "Ok(Some(v)) preserves the inner String payload" {
  val r: Result[Option[String], NErr] = Ok(Some(value = "payload"))
  assertEqual(innerOf(r, "MISS"), "payload", "inner String round-trips")
}

// ─────────────────────────────────────────────────────────────────────────────
// The end-to-end map-driven shape from the #1687 repro
// ─────────────────────────────────────────────────────────────────────────────

test "lookup miss yields Ok(None)" {
  val store: Map[String, String] = newMap()
  assertEqualInt(classify(lookupF(store, "absent")), 1, "missing key -> Ok(None)")
}

test "lookup hit yields Ok(Some(value))" {
  val store: Map[String, String] = newMap()
  store["k"] = "v"
  assertEqualInt(classify(lookupF(store, "k")), 2, "present key -> Ok(Some)")
  assertEqual(innerOf(lookupF(store, "k"), "MISS"), "v", "present key value")
}

// ─────────────────────────────────────────────────────────────────────────────
// Option[Int] nesting — guards against type-arg erasure on the integer path
// ─────────────────────────────────────────────────────────────────────────────

func classifyInt(r: in Result[Option[Int], NErr]): Int {
  match r {
    case Err(_)  -> 0
    case Ok(opt) -> match opt {
      case None    -> 1
      case Some(_) -> 2
    }
  }
}

test "Ok(None) for Result[Option[Int], E] matches None" {
  val r: Result[Option[Int], NErr] = Ok(None)
  assertEqualInt(classifyInt(r), 1, "Ok(None) Int classifies as Ok->None")
}

test "Ok(Some(n)) for Result[Option[Int], E] matches Some" {
  val r: Result[Option[Int], NErr] = Ok(Some(value = 7))
  assertEqualInt(classifyInt(r), 2, "Ok(Some) Int classifies as Ok->Some")
}
