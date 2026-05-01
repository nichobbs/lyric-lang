module Lyric.Emitter.Tests.AsyncTests

open System.IO
open System.Reflection
open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let private mk (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0
            (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            "stdout matches expected"

/// Per D-progress-024 (C2 Phase A), `async func` whose body contains
/// no internal `await` lowers to a real `IAsyncStateMachine` class
/// with `<>1__state` / `<>t__builder` fields, a `MoveNext` carrying
/// the user body, and a kickoff stub that calls
/// `AsyncTaskMethodBuilder<T>.Start` and returns `builder.Task`.
/// `await` at call sites still uses the M1.4 `GetAwaiter().GetResult()`
/// shim — these test cases all run synchronously through the SM and
/// the awaited Task is already-completed when the caller reaches
/// `GetAwaiter().GetResult()`.
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

    "async_block_with_locals",
    // Block body with local bindings + arithmetic — exercises the
    // exit-label / result-local path through the SM.
    """
package E14
async func compute(a: in Int, b: in Int): Int {
  val x = a * 2
  val y = b * 3
  x + y
}
func main(): Unit {
  println(await compute(4, 5))
}
""",
    "23"
]

let private behavioral =
    testSequenced
    <| testList "async — Phase A state-machine (E14 / D-progress-024)"
        (cases |> List.map mk)

/// Inspect the emitted assembly to confirm the Phase A SM class was
/// actually synthesised: a sibling top-level type named
/// `<funcname>__SM_<n>` implementing `IAsyncStateMachine`.  Catches
/// regressions where the routing flag flips back to the M1.4
/// `Task.FromResult` shim without anyone noticing.
let private smShape : Test =
    testCase "[sm_shape] async func emits IAsyncStateMachine class" <| fun () ->
        let label = "AsyncSmShape"
        let source = """
package E14
async func twice(n: in Int): Int = n + n
func main(): Unit {
  println(await twice(21))
}
"""
        let outDir = prepareOutputDir label
        let dll    = Path.Combine(outDir, label + ".dll")
        let req : Lyric.Emitter.Emitter.EmitRequest =
            { Source       = source
              AssemblyName = label
              OutputPath   = dll }
        let _ = Lyric.Emitter.Emitter.emit req
        let asm = Assembly.LoadFrom dll
        let smTypes =
            asm.GetTypes()
            |> Array.filter (fun t ->
                typeof<System.Runtime.CompilerServices.IAsyncStateMachine>.IsAssignableFrom(t))
        Expect.isGreaterThanOrEqual smTypes.Length 1
            "expected at least one IAsyncStateMachine implementation"
        let sm = smTypes.[0]
        let stateField = sm.GetField "<>1__state"
        let builderField = sm.GetField "<>t__builder"
        Expect.isNotNull stateField "state field present"
        Expect.isNotNull builderField "builder field present"
        let nField = sm.GetField "n"
        Expect.isNotNull nField "param field 'n' present"

let tests =
    testList "async tests" [
        behavioral
        smShape
    ]
