//! A `Unit`-returning top-level function used as a value is a real
//! `System.Action` on dotnet (#7783).
//!
//! Every `(...) -> Unit` type maps to `System.Action`/`Action`N` on dotnet,
//! and a `Unit` lambda literal is built as one, but a bare function reference
//! (`run(bump)`) was built from an `object`-returning forwarding thunk as a
//! `Func<..., object>`.  Passing it to an `Action` parameter or field was
//! unverifiable IL (an `Action::Invoke` on a `Func` ran only by accident), and
//! adding it to a `List[() -> Unit]` — a real `List<Action>` — threw
//! `ArrayTypeMismatchException`.  The thunk is now `void` and wrapped in an
//! `Action`, like the lambda literal.  Each case records what ran, so a call
//! that silently did nothing fails too.  Runs on dotnet and JVM; the dotnet
//! test DLL is verified by `scripts/ilverify-selfhosted.sh` phase 4.
@test_module
package UnitFuncRefActionSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func log(): List[String] {
  val l: List[String] = newList()
  l
}

record Recorder {
  seen: List[String]
}

func noteA(r: in Recorder): Unit {
  r.seen.add("a")
}

func noteB(r: in Recorder): Unit {
  r.seen.add("b")
}

func run(f: in (Recorder) -> Unit, r: in Recorder): Unit {
  f(r)
}

record Holder {
  act: (Recorder) -> Unit
}

func pick(): (Recorder) -> Unit = noteB

func pass[T](x: in T): T = x

func joined(r: in Recorder): String {
  var s = ""
  for x in r.seen {
    s = s + x
  }
  s
}

test "a Unit function reference passed to a (T) -> Unit parameter" {
  val r = Recorder(seen = log())
  run(noteA, r)
  run(noteB, r)
  assertEqual(joined(r), "ab", "both references ran")
}

test "a Unit function reference in a typed local, a record field and a returned value" {
  val r = Recorder(seen = log())
  val f: (Recorder) -> Unit = noteA
  f(r)
  val h = Holder(act = noteB)
  h.act(r)
  pick()(r)
  assertEqual(joined(r), "abb", "local, field and returned references ran")
}

test "Unit function references stored in a List[(Recorder) -> Unit]" {
  val r = Recorder(seen = log())
  val g = { x: Recorder -> noteB(x) }
  val fs: List[(Recorder) -> Unit] = [noteA, g, noteA]
  for f in fs {
    f(r)
  }
  assertEqual(joined(r), "aba", "every stored reference ran in order")
}

test "a Unit function reference in a Map value, an unannotated local and a generic pass-through" {
  val r = Recorder(seen = log())
  val m: Map[String, (Recorder) -> Unit] = newMap()
  m["k"] = noteA
  val fromMap = m["k"]
  fromMap(r)
  val k = noteB
  k(r)
  val viaGeneric: (Recorder) -> Unit = pass(noteA)
  viaGeneric(r)
  assertEqual(joined(r), "aba", "map, local and generic references ran")
}
