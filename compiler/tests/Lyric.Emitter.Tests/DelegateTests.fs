/// Tests for delegate / higher-order function lowering (Phase 2, Step 1).
///
/// Lyric function types `(T) -> R` lower to .NET `Func<T,R>` delegate
/// types. Non-capturing lambda expressions `{ x: Int -> expr }` are
/// synthesised as private static methods and wrapped in a `newobj`
/// delegate constructor call.
module Lyric.Emitter.Tests.DelegateTests

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testSequenced
    <| testList "delegate lowering" [

        testCase "[lambda passed to HOF]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DelegA" """
package DelegA

func apply(f: in (Int) -> Int, x: in Int): Int {
  f(x)
}

func main(): Unit {
  println(apply({ n: Int -> n + 1 }, 5))
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "6" "apply lambda"

        testCase "[two-arg lambda]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DelegB" """
package DelegB

func combine(f: in (Int, Int) -> Int, a: in Int, b: in Int): Int {
  f(a, b)
}

func main(): Unit {
  println(combine({ x: Int, y: Int -> x + y }, 3, 4))
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "7" "two-arg lambda"

        testCase "[lambda stored in val]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DelegC" """
package DelegC

func apply(f: in (Int) -> Int, x: in Int): Int {
  f(x)
}

func main(): Unit {
  println(apply({ n: Int -> n * 2 }, 7))
  println(apply({ n: Int -> n + 10 }, 5))
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "14\n15" "multiple lambda calls"

        testCase "[HOF with bool-returning lambda]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DelegD" """
package DelegD

func applyPred(f: in (Int) -> Bool, x: in Int): Bool {
  f(x)
}

func main(): Unit {
  println(applyPred({ n: Int -> n > 5 }, 3))
  println(applyPred({ n: Int -> n > 5 }, 9))
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "False\nTrue" "bool-returning lambda"

        testCase "[HOF chained]" <| fun () ->
            let _, stdout, stderr, exitCode =
                compileAndRun "DelegE" """
package DelegE

func apply(f: in (Int) -> Int, x: in Int): Int {
  f(x)
}

func main(): Unit {
  val r = apply({ n: Int -> n + 1 }, apply({ n: Int -> n * 2 }, 3))
  println(r)
}
"""
            Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
            Expect.equal (stdout.TrimEnd()) "7" "chained HOF"
    ]
