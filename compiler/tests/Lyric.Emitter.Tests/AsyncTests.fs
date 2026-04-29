module Lyric.Emitter.Tests.AsyncTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

/// Per D035, M1.4 ships a *blocking* async shim: `async func` lowers
/// to a CLR method returning `Task<T>` whose body runs synchronously
/// before wrapping the value in `Task.FromResult<T>(...)`. `await`
/// lowers to `.GetAwaiter().GetResult()`. Real C#-style state
/// machines are Phase 2 work.
let private cases : (string * string * string) list = [

    "await_int",
    """
package E14
async func twice(n: in Int): Int = n + n
func main(): Unit {
  println(await twice(21))
}
""",
    "42"

    "await_string",
    // Phase 1's binary `+` doesn't yet handle string concatenation
    // (the codegen emits an arithmetic add); the async return path
    // is what's being verified here.
    """
package E14
async func passthrough(name: in String): String = name
func main(): Unit {
  println(await passthrough("alice"))
}
""",
    "alice"

    "two_async_calls",
    """
package E14
async func add(a: in Int, b: in Int): Int = a + b
func main(): Unit {
  val x = await add(1, 2)
  val y = await add(x, 10)
  println(y)
}
""",
    "13"

    "async_void",
    """
package E14
async func sayHi(): Unit { println("hi from async") }
func main(): Unit {
  await sayHi()
}
""",
    "hi from async"
]

let tests =
    testSequenced
    <| testList "async — blocking shim (E14)"
        (cases |> List.map mk)
