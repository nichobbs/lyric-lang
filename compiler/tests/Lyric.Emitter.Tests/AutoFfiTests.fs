/// End-to-end tests for C4 phase 1 — strict-match auto-FFI on
/// extern-type static methods (D-progress-026).
///
/// `extern type T = "Foo.Bar"` makes `T.method(args)` resolve to a
/// static method on `Foo.Bar` whenever exactly one overload matches
/// by `(name | PascalCase, arg-arity, arg-types)` — no
/// `@externTarget` declaration needed.  Ambiguous calls fall through
/// with a structured E0004 diagnostic.
module Lyric.Emitter.Tests.AutoFfiTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected "stdout matches expected"

let private cases : (string * string * string) list = [

    // Direct static method call by exact name; only one overload of
    // System.IO.Path.Combine matches (string, string).
    "auto_ffi_path_combine",
    """
package AF1
extern type Path = "System.IO.Path"

func main(): Unit {
  println(Path.Combine("/tmp", "x.txt"))
}
""",
    "/tmp/x.txt"

    // PascalCase fallback: lowercase Lyric-side `max` resolves to
    // CLR `System.Math.Max`.  Strict-match disambiguates by exact
    // (int, int) signature among Math.Max's many numeric overloads.
    "auto_ffi_math_max_pascalcase",
    """
package AF2
extern type Math = "System.Math"

func main(): Unit {
  println(Math.max(3, 7))
}
""",
    "7"

    // Three-arg static — System.IO.Path.Combine(string, string, string)
    // is a separate overload; the resolver picks the unique 3-arg form.
    "auto_ffi_path_combine_three_args",
    """
package AF3
extern type Path = "System.IO.Path"

func main(): Unit {
  println(Path.Combine("/a", "b", "c.txt"))
}
""",
    "/a/b/c.txt"

    // Returns void; the auto-FFI dispatch reports `System.Void` which
    // gets routed through the no-result-on-stack path.
    "auto_ffi_void_return",
    """
package AF4
extern type Console = "System.Console"

func main(): Unit {
  Console.WriteLine("hi")
}
""",
    "hi"
]

let tests =
    testSequenced
    <| testList "C4 phase 1 — strict-match auto-FFI"
                (cases |> List.map mk)
