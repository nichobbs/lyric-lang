/// End-to-end tests for `@derive(Json)` source-gen (Tier 2.3 /
/// D-progress-030).
///
/// For each `pub record T` annotated `@derive(Json)`, the synthesiser
/// appends a `T.toJson(self): String` function that serialises the
/// record's fields as a JSON object.  Nested records also annotated
/// `@derive(Json)` dispatch recursively to their own toJson.
module Lyric.Emitter.Tests.JsonDeriveTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    "json_derive_basic",
    """
package JD1
import Std.Core

@derive(Json)
pub record Person { name: String, age: Int }

func main(): Unit {
  val p = Person(name = "Alice", age = 30)
  println(Person.toJson(p))
}
""",
    "{\"name\":\"Alice\",\"age\":30}"

    "json_derive_nested_records",
    """
package JD2
import Std.Core

@derive(Json)
pub record Addr { city: String, zip: String }

@derive(Json)
pub record Person { name: String, addr: Addr }

func main(): Unit {
  val p = Person(name = "Bob", addr = Addr(city = "Berlin", zip = "10115"))
  println(Person.toJson(p))
}
""",
    "{\"name\":\"Bob\",\"addr\":{\"city\":\"Berlin\",\"zip\":\"10115\"}}"

    "json_derive_bool_field",
    """
package JD3
import Std.Core

@derive(Json)
pub record Flag { active: Bool, count: Int }

func main(): Unit {
  println(Flag.toJson(Flag(active = true, count = 7)))
  println(Flag.toJson(Flag(active = false, count = 0)))
}
""",
    "{\"active\":True,\"count\":7}\n{\"active\":False,\"count\":0}"

    "json_derive_records_without_annotation_dont_get_synthesised",
    """
package JD4
import Std.Core

pub record Plain { x: Int }

func main(): Unit {
  // No @derive(Json) → no Plain.toJson; this should print the int.
  val p = Plain(x = 42)
  println(p.x)
}
""",
    "42"
]

let tests =
    testSequenced
    <| testList "@derive(Json) source-gen (Tier 2.3 / D-progress-030)"
                (cases |> List.map mk)
