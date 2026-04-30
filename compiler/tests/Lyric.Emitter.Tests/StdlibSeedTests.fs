/// Tests for the Lyric-side standard library at
/// `compiler/lyric/std/core.l`, exercised via `import Std.Core`.
///
/// Each test program uses `import Std.Core` and the emitter resolves
/// that import by locating `core.l`, parsing it, and merging its items
/// into the user package before type-checking.  This validates both the
/// stdlib functions themselves and the multi-package import machinery.
module Lyric.Emitter.Tests.StdlibSeedTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Locate `compiler/lyric/std/` from the test binary. We walk
/// up parent directories until the directory is found (typical
/// structure is `compiler/tests/Lyric.Emitter.Tests/bin/Debug/net9.0/`).
let private locateStdlibDir () : string =
    let mutable dir = Some (DirectoryInfo(System.AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "lyric", "std")
        if Directory.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj
    match found with
    | Some p -> p
    | None ->
        failwithf "could not locate lyric/std directory from %s"
            System.AppContext.BaseDirectory

/// Load every `.l` file under `compiler/lyric/std/` and strip each
/// file's `package` declaration. This lets the tests inline the
/// stdlib seed into the user's package while preserving separate
/// source files for future multi-package work.
let private loadStdlibBody () : string =
    let stdlibDir = locateStdlibDir ()
    Directory.GetFiles(stdlibDir, "*.l")
    |> Array.sort
    |> Array.map (fun path ->
        let raw = File.ReadAllText(path)
        raw.Split('\n')
        |> Array.filter (fun line ->
            let t = line.TrimStart()
            not (t.StartsWith "package "))
        |> String.concat "\n")
    |> String.concat "\n"

/// Wrap `driver` (which should not contain its own `package` line)
/// inside a freshly-named package and prefix it with the inlined
/// stdlib body.
let private wrap (label: string) (driver: string) : string =
    sprintf "package %s\n%s\n%s\n" label (loadStdlibBody ()) driver

let private mk (label: string, driver: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun label driver
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private cases : (string * string * string) list = [

    "option_unwrap_or",
    """
package StdTest_OptionUnwrapOr
import Std.Core
func main(): Unit {
  println(unwrapOr(Some(value = 42), 0))
  println(unwrapOr(None, 99))
}
""",
    "42\n99"

    "option_predicates",
    """
package StdTest_OptionPredicates
import Std.Core
func main(): Unit {
  println(isSome(Some(value = 1)))
  println(isSome(None))
  println(isNone(None))
}
""",
    "True\nFalse\nTrue"

    "generic_option_string",
    """
func main(): Unit {
  val some: Option[String] = Some(value = "hello")
  println(unwrapOr(some, "missing"))
  val none: Option[String] = None
  println(unwrapOr(none, "missing"))
}
""",
    "hello\nmissing"

    "result_basics",
    """
package StdTest_ResultBasics
import Std.Core
func main(): Unit {
  println(isOk(Ok(value = 7)))
  println(isOk(Err(code = 1)))
  println(unwrapResultOr(Ok(value = 7), 0))
  println(unwrapResultOr(Err(code = 1), 99))
  println(errCode(Err(code = 42)))
}
""",
    "True\nFalse\n7\n99\n42"

    "generic_result_string_int",
    """
func main(): Unit {
  val ok: Result[String, Int] = Ok(value = "ok")
  println(isOk(ok))
  println(isErr(ok))
  println(unwrapResultOr(ok, "fallback"))
  val err: Result[String, Int] = Err(code = 42)
  println(isOk(err))
  println(isErr(err))
  println(unwrapErrOr(err, 999))
}
""",
    "True\nFalse\nok\nFalse\nTrue\n42"

    "slice_helpers",
    """
package StdTest_SliceHelpers
import Std.Core
func main(): Unit {
  val xs = [3, 1, 4, 1, 5, 9, 2, 6]
  println(sumInts(xs))
  println(maxInt(xs))
  println(countEq(xs, 1))
}
""",
    "31\n9\n2"

    "mapOption",
    """
package StdTest_MapOption
import Std.Core
func main(): Unit {
  println(isSome(mapOption(Some(value = 3), { x: Int -> x * 2 })))
  println(unwrapOr(mapOption(Some(value = 3), { x: Int -> x * 2 }), 0))
  println(isSome(mapOption(None, { x: Int -> x * 2 })))
}
""",
    "True\n6\nFalse"

    "mapResult",
    """
package StdTest_MapResult
import Std.Core
func main(): Unit {
  println(isOk(mapResult(Ok(value = 5), { x: Int -> x + 1 })))
  println(unwrapResultOr(mapResult(Ok(value = 5), { x: Int -> x + 1 }), 0))
  println(isOk(mapResult(Err(code = 42), { x: Int -> x + 1 })))
}
""",
    "True\n6\nFalse"

    "filterOption",
    """
package StdTest_FilterOption
import Std.Core
func main(): Unit {
  println(isSome(filterOption(Some(value = 10), { x: Int -> x > 5 })))
  println(isSome(filterOption(Some(value = 3), { x: Int -> x > 5 })))
  println(isSome(filterOption(None, { x: Int -> x > 5 })))
}
""",
    "True\nFalse\nFalse"

    "countWhere",
    """
package StdTest_CountWhere
import Std.Core
func main(): Unit {
  val xs = [1, 2, 3, 4, 5, 6]
  println(countWhere(xs, { x: Int -> x > 3 }))
  println(countWhere(xs, { x: Int -> x == 2 }))
}
""",
    "3\n1"

    "string_length",
    """
func main(): Unit {
  println("hello".length)
  println("".length)
  println("xyz".length)
}
""",
    "5\n0\n3"

    "string_operations",
    """
func main(): Unit {
  val s = "  hello  "
  println(s.trim().length)
  println("hello".startsWith("hel"))
  println("hello".endsWith("lo"))
  println("hello".contains("ll"))
}
""",
    "5\nTrue\nTrue\nTrue"
]

/// Smoke test for string concatenation.
let private concatTests : Test list = [
    testCase "[string + string]" <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun "ConcatA" """
package ConcatA
func main(): Unit {
  println("hello, " + "world")
}
"""
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) "hello, world" "concat works"

    testCase "[string + int auto-boxes]" <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun "ConcatB" """
package ConcatB
func main(): Unit {
  println("count=" + 42)
}
"""
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) "count=42" "string + int"

    testCase "[int + string auto-boxes]" <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun "ConcatC" """
package ConcatC
func main(): Unit {
  println(42 + " is the answer")
}
"""
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) "42 is the answer" "int + string"
]

let tests =
    testSequenced
    <| testList "stdlib seed (S1 + S2)"
        (List.append
            (cases |> List.map mk)
            concatTests)
