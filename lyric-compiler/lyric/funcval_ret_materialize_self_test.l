//! funcval_ret_materialize_self_test.l — runtime regression test for #6511's
//! MSIL funcval-invoke materialization fixes: a function-typed parameter's
//! invoke result is DOWNCAST to its declared reference-class return type
//! (previously left verifier-typed `object`, producing invalid IL at any
//! concretely-typed `ret` — the `Mq.NativeQueue::consume` StackUnexpected),
//! and a lambda passed directly to a function-typed parameter inherits that
//! parameter's declared RETURN type as its logical return, so union-case
//! constructions in the body instantiate against the declared
//! `Result[T, E]` shape instead of the fully-erased `<object,object>` form
//! (previously an InvalidCastException once the downcast existed).  The
//! interface-impl indirection reproduces the exact shape that failed:
//! impl method returns `handler(x)` directly with a concretely-typed
//! declared return.  Runs on BOTH targets (the JVM backend is expected
//! unaffected; the test pins parity).
@test_module
package Lyric.FuncvalRetMaterializeSelfTest

import Std.Core
import Std.Testing

pub record Box {
  tag: String
}

pub interface Runner {
  func run(x: in Int, handler: (Box) -> Result[Unit, String]): Result[Unit, String]
}

pub record NativeRunner {
  id: Int
}

impl Runner for NativeRunner {
  func run(x: in Int, handler: (Box) -> Result[Unit, String]): Result[Unit, String] {
    val b = Box(tag = "t" + toString(x))
    return handler(b)
  }
}

pub func runIt(r: in Runner, x: in Int, handler: (Box) -> Result[Unit, String]): Result[Unit, String] {
  return r.run(x, handler)
}

test "lambda Result flows through impl-method return and matches" {
  val r = NativeRunner(id = 1)
  val res = runIt(r, 7, { b: Box -> if b.tag == "t7" { Ok(()) } else { Err("wrong tag: " + b.tag) } })
  match res {
    case Ok(_) -> assertTrue(true, "Ok flowed through the impl-method return")
    case Err(m) -> assertTrue(false, "expected Ok, got Err: " + m)
  }
}

test "lambda Err carries its payload through the same path" {
  val r = NativeRunner(id = 2)
  val res = runIt(r, 3, { b: Box -> if b.tag == "t999" { Ok(()) } else { Err("saw " + b.tag) } })
  match res {
    case Ok(_) -> assertTrue(false, "expected Err")
    case Err(m) -> assertEqual(m, "saw t3", "Err payload round-trips")
  }
}

test "zero-branch Ok callback flows through unchanged" {
  val r = NativeRunner(id = 3)
  val res = runIt(r, 5, { b: Box -> Ok(()) })
  match res {
    case Ok(_) -> assertTrue(true, "trivial Ok callback")
    case Err(_) -> assertTrue(false, "unexpected Err")
  }
}

// The IN-BUNDLE generic-union return shape (#6513): the declared callback
// return `Wrap[Int]` is a same-package generic union, so its MsilType is the
// by-name form whose head already carries the arity suffix — the downcast
// target must use it as-is (double-suffixing degraded to a no-op
// `castclass object`, reproducing the original invalid-IL bug for exactly
// this shape while the cross-package `Result` cases above passed).
pub union Wrap[T] {
  case Full(item: T)
  case Empty
}

pub interface WrapRunner {
  func run(x: in Int, handler: (Box) -> Wrap[Int]): Wrap[Int]
}

pub record NativeWrapRunner {
  id: Int
}

impl WrapRunner for NativeWrapRunner {
  func run(x: in Int, handler: (Box) -> Wrap[Int]): Wrap[Int] {
    val b = Box(tag = "w" + toString(x))
    return handler(b)
  }
}

pub func runWrap(r: in WrapRunner, x: in Int, handler: (Box) -> Wrap[Int]): Wrap[Int] {
  return r.run(x, handler)
}

test "in-bundle generic union return flows through impl-method return" {
  val r = NativeWrapRunner(id = 9)
  val res = runWrap(r, 4, { b: Box -> if b.tag == "w4" { Wrap.Full(item = 42) } else { Wrap.Empty } })
  match res {
    case Full(v) -> assertEqualInt(v, 42, "Full payload survives the downcast path")
    case Empty -> assertTrue(false, "expected Full")
  }
}
