/// End-to-end tests for `out` / `inout` parameters.
///
/// Lyric's `out` / `inout` lower to CLR byref slots; the call site
/// takes the argument's address (`Ldloca` for locals, `Ldarg` for
/// already-byref parameters), the body dereferences via `Ldobj` /
/// `Stobj`.  Definite-assignment analysis ensures every `out`
/// parameter is written along every normal-completion path.
module Lyric.Emitter.Tests.OutParamTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    // Basic out param: callee writes through the byref, caller sees
    // the new value.
    "out_param_basic",
    """
package OP1
func setIt(x: out Int): Unit {
  x = 42
}

func main(): Unit {
  var v = 0
  setIt(v)
  println(v)
}
""",
    "42"

    // inout param: callee reads + writes.  Caller sees the mutation.
    "inout_param_increments",
    """
package OP2
func bumpBy(x: inout Int, by: in Int): Unit {
  x = x + by
}

func main(): Unit {
  var v = 10
  bumpBy(v, 5)
  bumpBy(v, 5)
  println(v)
}
""",
    "20"

    // Definite-assignment: both branches assign — passes.
    "out_da_both_branches",
    """
package OP3
func setIt(x: out Int, cond: in Bool): Unit {
  if cond {
    x = 1
  } else {
    x = 0
  }
}

func main(): Unit {
  var v = 0
  setIt(v, true)
  println(v)
  setIt(v, false)
  println(v)
}
""",
    "1\n0"

    // Definite-assignment: early-return path that does assign passes.
    "out_da_early_return_with_assign",
    """
package OP4
func setIt(x: out Int, cond: in Bool): Bool {
  if cond {
    x = 42
    return true
  }
  x = 0
  return false
}

func main(): Unit {
  var v = 0
  val ok = setIt(v, true)
  println(v)
  println(ok)
}
""",
    "42\nTrue"

    // Forwarding: passing an `out` arg directly to another `out` param
    // counts as assigning the outer parameter.
    "out_da_forwarded",
    """
package OP5
func setItInner(x: out Int): Unit {
  x = 7
}

func setItOuter(x: out Int): Unit {
  setItInner(x)
}

func main(): Unit {
  var v = 0
  setItOuter(v)
  println(v)
}
""",
    "7"

    // FFI integration: Dictionary.TryGetValue via `out` param.
    "ffi_dictionary_try_get_value",
    """
package OP6
import Std.Core
import Std.Collections

func main(): Unit {
  val m: Map[String, Int] = newMap()
  m.add("alice", 30)
  match mapGet(m, "alice") {
    case Some(v) -> println(v)
    case None    -> println("missing")
  }
  match mapGet(m, "carol") {
    case Some(v) -> println(v)
    case None    -> println("missing")
  }
}
""",
    "30\nmissing"

    // default[T]() picks its CLR type from the val ascription.
    // Reference types (String) default to null per CLR semantics —
    // here we only exercise value types.
    "default_picks_type_from_ascription",
    """
package OP7
func main(): Unit {
  var n: Int = default()
  var b: Bool = default()
  var l: Long = default()
  println(n)
  println(b)
  println(l)
}
""",
    "0\nFalse\n0"

    // Inout used as accumulator.
    "inout_accumulator",
    """
package OP8
func addAll(total: inout Int, xs: in slice[Int]): Unit {
  for x in xs {
    total = total + x
  }
}

func main(): Unit {
  var t = 100
  addAll(t, [1, 2, 3, 4])
  println(t)
}
""",
    "110"

    // B3: array element as an `out` target — the codegen takes the
    // element's address (`Ldelema`), the callee writes through the
    // byref, the caller sees the mutated slot.
    "out_array_element_target",
    """
package OP9
func setIt(x: out Int): Unit { x = 99 }

func main(): Unit {
  val xs = [10, 20, 30]
  setIt(xs[1])
  for x in xs { println(x) }
}
""",
    "10\n99\n30"

    // B3: record field as an `out` target — `Ldflda` produces the
    // field address, the callee writes via the byref.
    "out_record_field_target",
    """
package OP10
record Pt { x: Int, y: Int }

func setIt(t: out Int): Unit { t = 99 }

func main(): Unit {
  val p = Pt(x = 1, y = 2)
  setIt(p.x)
  println(p.x)
  println(p.y)
}
""",
    "99\n2"
]

let tests =
    testSequenced
    <| testList "out / inout parameters" (cases |> List.map mk)
