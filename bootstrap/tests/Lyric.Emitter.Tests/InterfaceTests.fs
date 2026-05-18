module Lyric.Emitter.Tests.InterfaceTests

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

    "single_method_dispatch",
    """
package E12
interface Greeter { func greet(): String }
record EnglishGreeter { name: String }
impl Greeter for EnglishGreeter {
  func greet(): String = "hello, world"
}
func main(): Unit {
  val g = EnglishGreeter(name = "Alice")
  println(g.greet())
}
""",
    "hello, world"

    "interface_param_dispatch",
    """
package E12
interface Greeter { func greet(): String }
record EnglishGreeter { x: Int }
record ShoutyGreeter  { x: Int }
impl Greeter for EnglishGreeter { func greet(): String = "hi" }
impl Greeter for ShoutyGreeter  { func greet(): String = "HI!" }
func say(g: in Greeter): Unit {
  println(g.greet())
}
func main(): Unit {
  say(EnglishGreeter(x = 1))
  say(ShoutyGreeter(x = 1))
}
""",
    "hi\nHI!"

    "method_uses_self_field",
    """
package E12
interface Counter { func value(): Int }
record IntCounter { v: Int }
impl Counter for IntCounter {
  func value(): Int = self.v
}
func main(): Unit {
  println(IntCounter(v = 42).value())
}
""",
    "42"

    "method_with_param",
    """
package E12
interface Adder { func add(x: in Int): Int }
record OffsetAdder { base: Int }
impl Adder for OffsetAdder {
  func add(x: in Int): Int = self.base + x
}
func main(): Unit {
  println(OffsetAdder(base = 10).add(5))
}
""",
    "15"
]

let tests =
    testSequenced
    <| testList "interfaces + dispatch (E12)"
        (cases |> List.map mk)
