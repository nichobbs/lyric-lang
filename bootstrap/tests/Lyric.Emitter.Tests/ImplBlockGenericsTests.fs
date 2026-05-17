module Lyric.Emitter.Tests.ImplBlockGenericsTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private cases : (string * string * string) list = [

    // -----------------------------------------------------------------------
    // Case 1 — Method-level generics in a non-generic impl block.
    // The method `func name[U]` is itself a generic CLR method; the record
    // target has no generic parameters.
    // -----------------------------------------------------------------------

    "method_generic_identity",
    """
package IBG1
interface Wrapper { func wrap[U](x: in U): U }
record NoOp { }
impl Wrapper for NoOp {
  func wrap[U](x: in U): U = x
}
func main(): Unit {
  val w = NoOp()
  println(w.wrap(42))
  println(w.wrap("hello"))
}
""",
    "42\nhello"

    "method_generic_two_params",
    """
package IBG2
interface Pair { func pair[A, B](a: in A, b: in B): A }
record Selector { }
impl Pair for Selector {
  func pair[A, B](a: in A, b: in B): A = a
}
func main(): Unit {
  val s = Selector()
  println(s.pair(7, "ignored"))
  println(s.pair("kept", 99))
}
""",
    "7\nkept"

    "method_generic_uses_self_field",
    """
package IBG3
interface Applicator { func apply[T](x: in T): T }
record Doubler { scale: Int }
impl Applicator for Doubler {
  func apply[T](x: in T): T = x
}
func main(): Unit {
  val d = Doubler(scale = 2)
  println(d.apply(100))
  println(d.apply("word"))
}
""",
    "100\nword"

    // -----------------------------------------------------------------------
    // Case 2 — Impl-block-level generics.
    // `impl[T]` means T comes from the record's own class-level GTPBs.
    // The method is not itself generic but its return type references T
    // indirectly via `self.tag` (an Int field), not via T directly.
    // -----------------------------------------------------------------------

    "impl_generic_value_roundtrip",
    """
package IBG4
interface Holder { func get(): Int }
generic[T] record Box { value: T, tag: Int }
impl[T] Holder for Box[T] {
  func get(): Int = self.tag
}
func main(): Unit {
  val b = Box(value = "hi", tag = 7)
  println(b.get())
}
""",
    "7"

    "impl_generic_two_impls",
    """
package IBG5
interface Named { func name(): String }
generic[T] record Tagged { item: T, label: String }
impl[T] Named for Tagged[T] {
  func name(): String = self.label
}
func main(): Unit {
  val t1 = Tagged(item = 42,    label = "alpha")
  val t2 = Tagged(item = "xyz", label = "beta")
  println(t1.name())
  println(t2.name())
}
""",
    "alpha\nbeta"

    // -----------------------------------------------------------------------
    // Case 3 — Combined: impl-block generics + method-level generics.
    // -----------------------------------------------------------------------

    "impl_and_method_generic",
    """
package IBG6
interface Transformer { func transform[U](x: in U): U }
generic[T] record Container { value: T }
impl[T] Transformer for Container[T] {
  func transform[U](x: in U): U = x
}
func main(): Unit {
  val c = Container(value = 1)
  println(c.transform(99))
  println(c.transform("ok"))
}
""",
    "99\nok"

]

let tests =
    testSequenced
    <| testList "impl-block generics (IBG)"
        (cases |> List.map mk)
