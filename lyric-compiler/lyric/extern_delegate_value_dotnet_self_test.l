//! extern_delegate_value_dotnet_self_test.l — a `Unit`-returning closure
//! reaching an `@externTarget` function's `() -> Unit` parameter (bridged to
//! a real `System.Action`, D122/docs/50) through every argument shape, not
//! just a lambda literal written at the call site (#7520).
//!
//! Before the fix, a lambda bound to a `() -> Unit` local
//! (`val work: () -> Unit = { -> ... }`) or passed to an ordinary
//! higher-order function's `() -> Unit` parameter was constructed as a
//! `System.Action` delegate (the construction site read the real `Unit`
//! return from `lambdaRetTypes`, #5329) around a lifted `__lambda_<i>`
//! method whose own signature still returned `object` (the lifted method's
//! return type only consulted the FFI-literal registry).  The CLR does not
//! check `ldftn object __lambda_N(...)` + `newobj Action::.ctor` at run time,
//! but the IL is unverifiable: `ilverify` rejected
//! `Std.ConsoleHost.startStdinRead` and
//! `Std.ProcessPipedHost.ensureBackgroundRead` with
//! `[DelegateCtor] Unrecognized arguments for delegate .ctor`.  Both sites
//! now share `lambdaReturnsVoidMsil` (`lyric-compiler/msil/codegen.l`).
//! The same mismatch hit every `() -> Unit` lambda passed to an ordinary
//! higher-order function (#7166), covered by the last case.
//!
//! The closure reaches the extern as a literal, an annotated local, a
//! forwarded parameter, a record field, a function's return value, and a
//! typed `List`/`Map` element.
//! Every case runs the delegate on a thread-pool thread through the real
//! `Task.Run(Action)` and asserts the closure's observable side effect.
//! Beyond the runtime assertions, this module's emitted DLL is expected to
//! be `ilverify`-clean (the gate in `scripts/ilverify-selfhosted.sh` covers
//! the stdlib kernels that motivated the fix).
//!
//! `--target dotnet` only: `System.Threading.Tasks.Task` is a .NET type.  The
//! JVM target has no D122 delegate-bridging path — a Lyric function value is
//! already a `java.util.function` functional-interface instance on every
//! route (see `jvm_lambda_iface_bundling_self_test.l`).
//!
//!   lyric test lyric-compiler/lyric/extern_delegate_value_dotnet_self_test.l
@test_module
package ExternDelegateValueDotnetSelfTest

import Std.Core
import Std.Testing

extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externInstance
@externTarget("System.Threading.Tasks.Task.Wait")
func taskWait(t: in Task): Unit = ()

record Sink {
  items: List[Int]
  errors: List[String]
}

func newSink(): Sink = Sink(items = newList(), errors = newList())

func runNow(work: in () -> Unit): Unit {
  taskWait(taskRun(work))
}

func runViaLocal(s: in Sink, v: in Int): Unit {
  val handle = s
  val work: () -> Unit = { -> handle.items.add(v) }
  taskWait(taskRun(work))
}

func runViaLocalWithTry(s: in Sink, fail: in Bool): Unit {
  val handle = s
  val work: () -> Unit = { ->
    try {
      if fail {
        panic("boom")
      }
      handle.items.add(7)
    } catch Bug as b {
      handle.errors.add(b.message)
    }
  }
  taskWait(taskRun(work))
}

record Job {
  run: () -> Unit
}

test "lambda literal passed straight to the extern" {
  val s = newSink()
  taskWait(taskRun({ -> s.items.add(1) }))
  assertTrue(s.items.count == 1 and s.items[0] == 1, "literal ran once")
}

test "lambda bound to a () -> Unit local capturing a record" {
  val s = newSink()
  runViaLocal(s, 2)
  runViaLocal(s, 3)
  assertTrue(s.items.count == 2, "both local closures ran (got " + toString(s.items.count) + ")")
  assertTrue(s.items[0] == 2 and s.items[1] == 3, "captured values in order")
}

test "local closure with a try/catch body, both outcomes" {
  val s = newSink()
  runViaLocalWithTry(s, false)
  runViaLocalWithTry(s, true)
  assertTrue(s.items.count == 1 and s.items[0] == 7, "success path ran")
  assertTrue(s.errors.count == 1 and s.errors[0] == "boom", "failure path caught the bug")
}

test "function parameter forwarded to the extern" {
  val s = newSink()
  runNow({ -> s.items.add(4) })
  val work: () -> Unit = { -> s.items.add(5) }
  runNow(work)
  assertTrue(s.items.count == 2, "both forwarded closures ran (got " + toString(s.items.count) + ")")
  assertTrue(s.items[0] == 4 and s.items[1] == 5, "forwarded values in order")
}

test "local closure is still directly callable" {
  val s = newSink()
  val work: () -> Unit = { -> s.items.add(6) }
  work()
  taskWait(taskRun(work))
  assertTrue(s.items.count == 2, "direct call plus extern run (got " + toString(s.items.count) + ")")
}

test "closure read from a record field" {
  val s = newSink()
  val job = Job(run = { -> s.items.add(8) })
  taskWait(taskRun(job.run))
  assertTrue(s.items.count == 1 and s.items[0] == 8, "field closure ran")
}

func makeWork(s: in Sink, v: in Int): () -> Unit {
  { -> s.items.add(v) }
}

func makeWorkAfterOtherLambdas(s: in Sink, v: in Int): () -> Unit {
  val doubled: () -> Int = { -> v * 2 }
  val w = doubled()
  { -> s.items.add(w) }
}

func makeWorkByReturn(s: in Sink, v: in Int): () -> Unit {
  return { -> s.items.add(v) }
}

test "closure returned from a function" {
  val s = newSink()
  taskWait(taskRun(makeWork(s, 9)))
  taskWait(taskRun(makeWorkAfterOtherLambdas(s, 5)))
  taskWait(taskRun(makeWorkByReturn(s, 11)))
  assertTrue(s.items.count == 3, "returned closures ran (got " + toString(s.items.count) + ")")
  assertTrue(s.items[0] == 9 and s.items[1] == 10 and s.items[2] == 11, "returned closures' values in order")
}

func applyUnit(g: in () -> Unit): Unit {
  g()
}

func applyUnit1(g: in (Int) -> Unit, v: in Int): Unit {
  g(v)
}

func applyInt(g: in () -> Int): Int = g()

func applyInt1(g: in (Int) -> Int, v: in Int): Int = g(v)

test "ordinary higher-order functions, Unit and non-Unit returns (#7166)" {
  val s = newSink()
  applyUnit({ -> s.items.add(12) })
  applyUnit1({ x -> s.items.add(x) }, 13)
  val k = 30
  val viaInt = applyInt({ -> k + 1 })
  val viaInt1 = applyInt1({ x -> x * k }, 2)
  assertTrue(s.items.count == 2 and s.items[0] == 12 and s.items[1] == 13, "Unit-returning HOF lambdas ran")
  assertTrue(viaInt == 31 and viaInt1 == 60, "value-returning HOF lambdas returned their values")
}

test "closures stored in and read back from typed collections" {
  val s = newSink()
  val xs: List[() -> Unit] = newList()
  xs.add({ -> s.items.add(14) })
  xs.add(makeWork(s, 15))
  for f in xs {
    taskWait(taskRun(f))
  }
  xs[0]()
  val m: Map[String, () -> Unit] = newMap()
  m.add("k", { -> s.items.add(16) })
  match mapGet(m, "k") {
    case Some(h) -> taskWait(taskRun(h))
    case None -> ()
  }
  makeWork(s, 17)()
  assertTrue(s.items.count == 5, "collection closures ran (got " + toString(s.items.count) + ")")
  assertTrue(s.items[0] == 14 and s.items[1] == 15 and s.items[2] == 14, "list closures in order")
  assertTrue(s.items[3] == 16 and s.items[4] == 17, "map closure and chained factory call ran")
}
