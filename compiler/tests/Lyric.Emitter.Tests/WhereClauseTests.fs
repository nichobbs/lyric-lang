/// Tests for `where`-clause enforcement at generic call sites.
/// Definition-time well-formedness (T0050 / T0051) lands in the
/// type checker; this file covers the codegen-level B0001 check
/// that fires when the inferred type-arg doesn't satisfy a declared
/// derive marker.
module Lyric.Emitter.Tests.WhereClauseTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mkOk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private mkBoundFailure (label: string, source: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let mutable raised = false
        try
            compileAndRun label source |> ignore
        with
        | ex when ex.Message.Contains "B0001" -> raised <- true
        Expect.isTrue raised "B0001 was raised"

let private okCases : (string * string * string) list = [

    "compare_int_satisfies_compare_marker",
    """
package WC1
func minOf[T](a: T, b: T): T where T: Compare {
  if a < b { a } else { b }
}
func main(): Unit { println(minOf(7, 3)) }
""",
    "3"

    "string_satisfies_compare",
    """
package WC2
func minOf[T](a: T, b: T): T where T: Compare {
  if a < b { a } else { b }
}
func main(): Unit { println(minOf("apple", "banana")) }
""",
    "apple"

    "int_satisfies_add",
    """
package WC3
func twice[T](x: T): T where T: Add {
  x + x
}
func main(): Unit { println(twice(21)) }
""",
    "42"

    "multiple_markers_in_one_bound",
    """
package WC4
func go[T](a: T, b: T): T where T: Add + Compare {
  if a < b { b + a } else { a + b }
}
func main(): Unit { println(go(2, 5)) }
""",
    "7"

    // Q021 distinct-types derives gap: `type Age = Int derives Hash`
    // should satisfy `where T: Hash`.  Previously DistinctTypeInfo
    // didn't carry the derives list so this aborted with B0001.
    "distinct_type_derives_hash_satisfies_where",
    """
package WC8
type Age = Int derives Hash, Equals
func hashOf[T](x: T): Int where T: Hash { 42 }
func main(): Unit { println(hashOf(Age.from(30))) }
""",
    "42"

    // Compare marker via derives: `type Score = Int derives Compare`
    // satisfies `where T: Compare`.  The generic function only passes the
    // bound check; it doesn't perform Compare arithmetic on the type
    // argument (generic distinct-type arithmetic is a separate gap).
    "distinct_type_derives_compare_satisfies_where",
    """
package WC9
type Score = Int derives Compare, Equals
func isOrdered[T](a: T, b: T): Bool where T: Compare { true }
func main(): Unit {
  val a: Score = Score.from(10)
  val b: Score = Score.from(20)
  println(isOrdered(a, b))
}
""",
    "True"

    // Q021 sub-question #5: user-defined interface constraints. The
    // record `Bird` implements `Greeter`, so `T = Bird` satisfies
    // `where T: Greeter` and the call dispatches as a normal generic
    // call site.
    "user_interface_constraint_satisfied",
    """
package WC6
interface Greeter { func greet(): String }
record Bird { sound: String }
impl Greeter for Bird {
  func greet(): String = self.sound
}
func relay[T](g: in T): String where T: Greeter { g.greet() }
func main(): Unit { println(relay(Bird(sound = "tweet"))) }
""",
    "tweet"
]

let tests =
    testSequenced
    <| testList "where-clause enforcement (codegen)" [
        yield! okCases |> List.map mkOk

        // Boolean is `Equals/Hash/Default` per the bootstrap table but
        // not `Add` / `Sub` / `Compare`.  Calling `twice(true)` against
        // `where T: Add` fails the bound-check.
        yield mkBoundFailure (
            "bool_does_not_satisfy_add",
            "package WC5\n" +
            "func twice[T](x: T): T where T: Add { x + x }\n" +
            "func main(): Unit { println(twice(true)) }\n")

        // Distinct type without the required marker still fails B0001.
        yield mkBoundFailure (
            "distinct_type_without_derives_fails_bound",
            "package WC10\n" +
            "type Age = Int\n" +
            "func hashOf[T](x: T): Int where T: Hash { 42 }\n" +
            "func main(): Unit { println(hashOf(Age.from(30))) }\n")

        // Q021 sub-question #5 negative case: `Mute` does not implement
        // the `Greeter` interface, so `T = Mute` fails `where T: Greeter`
        // and the build aborts with B0001 instead of silently rejecting
        // every user-interface bound (the prior behaviour).
        yield mkBoundFailure (
            "user_interface_constraint_unsatisfied",
            "package WC7\n" +
            "interface Greeter { func greet(): String }\n" +
            "record Mute { x: Int }\n" +
            "func relay[T](g: in T): String where T: Greeter { \"unused\" }\n" +
            "func main(): Unit { println(relay(Mute(x = 1))) }\n")
    ]
