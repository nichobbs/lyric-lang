/// End-to-end tests for C6 — bootstrap-grade wire blocks
/// (D-progress-028).
///
/// `wire WireName { @provided p, singleton n: T = init, expose n }`
/// gets a synthesised record + `<WireName>.bootstrap(...providedArgs)`
/// factory.  Singletons are constructed in topological order; the
/// factory returns a `<WireName>` record with one field per `expose`d
/// component.
///
/// Bootstrap-grade scope (per docs/12-todo-plan.md C6 follow-ups):
/// scoped lifetimes, the lifetime checker, `@bind`-style multi-impl
/// registration, and AsyncLocal scope tracking are deferred — gated
/// on C2's real async work.
module Lyric.Emitter.Tests.WireTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "wire_minimal_singleton",
    """
package WR1
record Cfg { tag: String }

wire Prod {
  @provided n: String
  singleton cfg: Cfg = Cfg(tag = n)
  expose cfg
}

func main(): Unit {
  val w = Prod.bootstrap("alpha")
  println(w.cfg.tag)
}
""",
    "alpha"

    "wire_two_singletons_dependency_order",
    """
package WR2
record A { v: Int }
record B { a: A, n: Int }

wire W {
  @provided base: Int
  // b depends on a; topo sort emits a first.
  singleton b: B = B(a = a, n = base + 1)
  singleton a: A = A(v = base)
  expose b
}

func main(): Unit {
  val w = W.bootstrap(7)
  println(w.b.a.v)
  println(w.b.n)
}
""",
    "7\n8"

    "wire_multi_provided",
    """
package WR3
record Cfg { name: String, port: Int }

wire Prod {
  @provided name: String
  @provided port: Int
  singleton cfg: Cfg = Cfg(name = name, port = port)
  expose cfg
}

func main(): Unit {
  val w = Prod.bootstrap("svc", 8080)
  println(w.cfg.name)
  println(w.cfg.port)
}
""",
    "svc\n8080"

    "wire_two_wires_in_same_program",
    """
package WR4
record Cfg { tag: String }

wire ProductionWire {
  @provided p: String
  singleton cfg: Cfg = Cfg(tag = p)
  expose cfg
}

wire TestWire {
  singleton cfg: Cfg = Cfg(tag = "test")
  expose cfg
}

func main(): Unit {
  val pw = ProductionWire.bootstrap("real")
  val tw = TestWire.bootstrap()
  println(pw.cfg.tag)
  println(tw.cfg.tag)
}
""",
    "real\ntest"

    "wire_scoped_factory_synth",
    // D-progress-072: scoped lifetimes synthesise per-scope
    // factory functions.  `scoped[Request] req: ReqCtx = ...`
    // becomes `pub func RequestWire.scopedreq(): ReqCtx`.
    // Each call returns a fresh instance; the lifetime is the
    // request, not the program.
    """
package WR5
record ReqCtx { id: Int }

wire RequestWire {
  @provided baseId: Int
  singleton clock: Int = baseId
  scoped[Request] req: ReqCtx = ReqCtx(id = 101)
  expose clock
}

func main(): Unit {
  val w = RequestWire.bootstrap(1)
  println(toString(w.clock))
  val r1 = RequestWire.scopedreq()
  val r2 = RequestWire.scopedreq()
  println(toString(r1.id))
  println(toString(r2.id))
}
""",
    "1\n101\n101"
]

let tests =
    testSequenced
    <| testList "wire blocks bootstrap-grade (C6 / D-progress-028)"
                (cases |> List.map mk)
