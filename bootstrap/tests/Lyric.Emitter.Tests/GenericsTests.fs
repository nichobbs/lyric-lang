module Lyric.Emitter.Tests.GenericsTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

/// Per D035, M1.4 ships erasure-based monomorphisation: type
/// parameters lower to `obj` in the CLR signature and value-typed
/// call-site arguments box at the boundary. The CLR's
/// `Console.WriteLine(object)` overload prints boxed primitives via
/// the boxed value's `ToString()`, so end-to-end stdout assertions
/// still work for the simple cases the banking example needs.
let private cases : (string * string * string) list = [

    "identity_int",
    """
package E13
generic[T] func id(x: in T): T = x
func main(): Unit {
  println(id(42))
}
""",
    "42"

    "identity_string",
    """
package E13
generic[T] func id(x: in T): T = x
func main(): Unit {
  println(id("hello"))
}
""",
    "hello"

    "identity_bool",
    """
package E13
generic[T] func id(x: in T): T = x
func main(): Unit {
  println(id(true))
}
""",
    "True"

    "two_type_args",
    """
package E13
generic[A, B] func first(a: in A, b: in B): A = a
func main(): Unit {
  println(first(1, "ignored"))
  println(first("kept", 99))
}
""",
    "1\nkept"

    "generic_returning_string",
    // String stays as a reference type through erasure; the value
    // round-trips without an explicit unbox step. Mixing a generic
    // call into a value-typed slot (e.g. a record field) needs the
    // unbox-return polish that lands as part of the banking-example
    // smoke (E17).
    """
package E13
generic[T] func id(x: in T): T = x
func main(): Unit {
  val s = id("loop")
  println(s)
  println(s)
}
""",
    "loop\nloop"
]

/// Reified-generics regressions: walks `MethodInfo.IsGenericMethodDefinition`
/// → `MakeGenericMethod`, with type-arg inference driven by Lyric param
/// types.  Existing erasure-era tests above are repurposed as the
/// behavioural baseline; the cases below pin down properties only the
/// reified path can satisfy.
let private reifiedCases : (string * string * string) list = [

    "generic_int_round_trip",
    """
package RG1
generic[T] func id(x: in T): T = x
func main(): Unit {
  println(id(42) + id(8))
}
""",
    "50"

    "generic_chain_through_two_calls",
    """
package RG2
generic[T] func id(x: in T): T = x
func main(): Unit {
  println(id(id(7)))
}
""",
    "7"
]

let tests =
    testSequenced
    <| testList "generics — reified monomorphisation"
        (List.append (cases |> List.map mk) (reifiedCases |> List.map mk))
