/// First-slice tests for the Lyric-side standard library at
/// `compiler/lyric/std/core.l`. Until multi-package compilation
/// lands (Phase 2), the test harness inlines `core.l`'s body into
/// the user program: the `package Std.Core` declaration is stripped
/// and the user's source provides its own `package` line followed
/// by every type and function defined in the seed.
///
/// These tests double as the regression suite that catches drift
/// between the seed and the M1.4 emitter capabilities — if a
/// language change breaks an Option/Result combinator the test
/// surfaces it immediately.
module Lyric.Emitter.Tests.StdlibSeedTests

open System.IO
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

/// Locate `compiler/lyric/std/core.l` from the test binary. We walk
/// up parent directories until the file is found (typical structure
/// is `compiler/tests/Lyric.Emitter.Tests/bin/Debug/net9.0/`, so the
/// seed lives four levels up).
let private locateCoreL () : string =
    let mutable dir = Some (DirectoryInfo(System.AppContext.BaseDirectory))
    let mutable found : string option = None
    while found.IsNone && dir.IsSome do
        let d = dir.Value
        let candidate = Path.Combine(d.FullName, "lyric", "std", "core.l")
        if File.Exists candidate then found <- Some candidate
        dir <- d.Parent |> Option.ofObj
    match found with
    | Some p -> p
    | None ->
        failwithf "could not locate lyric/std/core.l from %s"
            System.AppContext.BaseDirectory

/// Load `core.l` and strip its `package Std.Core` declaration so the
/// caller can stitch the body into its own package. Comment lines
/// at the top of the file are kept (the parser tolerates them as
/// pre-package whitespace once they're indented inside the user's
/// package, but it's simpler to drop them too).
let private loadStdlibBody () : string =
    let raw = File.ReadAllText(locateCoreL ())
    raw.Split('\n')
    |> Array.filter (fun line ->
        let t = line.TrimStart()
        not (t.StartsWith "package "))
    |> String.concat "\n"

/// Wrap `driver` (which should not contain its own `package` line)
/// inside a freshly-named package and prefix it with the inlined
/// stdlib body.
let private wrap (label: string) (driver: string) : string =
    sprintf "package %s\n%s\n%s\n" label (loadStdlibBody ()) driver

let private mk (label: string, driver: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode =
            compileAndRun label (wrap label driver)
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

let private cases : (string * string * string) list = [

    "option_unwrap_or",
    """
func main(): Unit {
  println(unwrapOr(Some(value = 42), 0))
  println(unwrapOr(None, 99))
}
""",
    "42\n99"

    "option_predicates",
    """
func main(): Unit {
  println(isSome(Some(value = 1)))
  println(isSome(None))
  println(isNone(None))
}
""",
    "True\nFalse\nTrue"

    "result_basics",
    """
func main(): Unit {
  println(isOk(Ok(value = 7)))
  println(isOk(Err(code = 1)))
  println(unwrapResultOr(Ok(value = 7), 0))
  println(unwrapResultOr(Err(code = 1), 99))
  println(errCode(Err(code = 42)))
}
""",
    "True\nFalse\n7\n99\n42"

    "slice_helpers",
    """
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
func main(): Unit {
  println(isSome(mapOption(Some(value = 3), { x: Int -> x * 2 })))
  println(unwrapOr(mapOption(Some(value = 3), { x: Int -> x * 2 }), 0))
  println(isSome(mapOption(None, { x: Int -> x * 2 })))
}
""",
    "True\n6\nFalse"

    "mapResult",
    """
func main(): Unit {
  println(isOk(mapResult(Ok(value = 5), { x: Int -> x + 1 })))
  println(unwrapResultOr(mapResult(Ok(value = 5), { x: Int -> x + 1 }), 0))
  println(isOk(mapResult(Err(code = 42), { x: Int -> x + 1 })))
}
""",
    "True\n6\nFalse"

    "filterOption",
    """
func main(): Unit {
  println(isSome(filterOption(Some(value = 10), { x: Int -> x > 5 })))
  println(isSome(filterOption(Some(value = 3), { x: Int -> x > 5 })))
  println(isSome(filterOption(None, { x: Int -> x > 5 })))
}
""",
    "True\nFalse\nFalse"

    "countWhere",
    """
func main(): Unit {
  val xs = [1, 2, 3, 4, 5, 6]
  println(countWhere(xs, { x: Int -> x > 3 }))
  println(countWhere(xs, { x: Int -> x == 2 }))
}
""",
    "3\n1"
]

/// Smoke test for the string-concatenation polish that this branch
/// adds alongside the seed. Lives here because it's the change that
/// lets stdlib-shaped formatters work.
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
