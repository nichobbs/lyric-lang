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

    // String fields go through the BCL's JsonEncodedText.Encode via
    // the synthesised __lyricJsonEscape extern.  Quotes, backslashes,
    // and control characters are escaped.
    "json_derive_string_escaping",
    """
package JD5
import Std.Core

@derive(Json)
pub record M { msg: String }

func main(): Unit {
  println(M.toJson(M(msg = "line1\nline2")))
}
""",
    "{\"msg\":\"line1\\nline2\"}"

    "json_derive_int_slice_field",
    // Phase 3 (D-progress-043): slice[Int] field rendering.
    """
package J7
@derive(Json)
pub record Page {
  total: Int
  items: slice[Int]
}
func main(): Unit {
  println(Page.toJson(Page(total = 3, items = [10, 20, 30])))
}
""",
    "{\"total\":3,\"items\":[10,20,30]}"

    "json_derive_string_slice_field",
    // String slice elements get JsonEncodedText.Encode'd individually.
    """
package J8
@derive(Json)
pub record Tags {
  values: slice[String]
}
func main(): Unit {
  println(Tags.toJson(Tags(values = ["a", "b\\nc", "\"q\""])))
}
""",
    "{\"values\":[\"a\",\"b\\\\nc\",\"\\u0022q\\u0022\"]}"

    "json_derive_bool_slice_field",
    """
package J9
@derive(Json)
pub record Flags {
  values: slice[Bool]
}
func main(): Unit {
  println(Flags.toJson(Flags(values = [true, false, true])))
}
""",
    "{\"values\":[true,false,true]}"

    "json_derive_record_slice_field",
    // D-progress-044: slice of @derive(Json) records lowers to a
    // synthesised __lyricJsonRender<RecName>Slice helper that
    // loops the slice and dispatches to <RecName>.toJson per
    // element.
    """
package J10
@derive(Json)
pub record Item {
  name: String
  count: Int
}
@derive(Json)
pub record Bag {
  items: slice[Item]
}
func main(): Unit {
  println(Bag.toJson(Bag(items = [
    Item(name = "a", count = 1),
    Item(name = "b", count = 2)
  ])))
}
""",
    "{\"items\":[{\"name\":\"a\",\"count\":1},{\"name\":\"b\",\"count\":2}]}"
]

let tests =
    testSequenced
    <| testList "@derive(Json) source-gen (Tier 2.3 / D-progress-030)"
                (cases |> List.map mk)
