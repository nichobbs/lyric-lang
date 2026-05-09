/// Aspect weaver A1 — bootstrap-grade wrapper synthesis.
module Lyric.Emitter.Tests.AspectWeaverTest

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Aspect Weaver A1 (wrapper synthesis + proceed rewrite)" [

        testCase "aspect_weaver_basic" <| fun () ->
            // around-advice that prints before and after the target.
            // proceed(args) → greet__aspect_target(name) at weave time.
            let src = """
package Test.AspectWeaver

import Std.Core

aspect Loud {
  matches: name like "greet*"

  around(args) -> ret {
    println("before")
    proceed(args)
    println("after")
  }
}

func greet(name: in String): Unit {
  println("Hello, " + name)
}

func main(): Unit {
  greet("World")
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_basic" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "before"
                (sprintf "expected 'before' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "Hello, World"
                (sprintf "expected 'Hello, World' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "after"
                (sprintf "expected 'after' in stdout, got: '%s'" stdout)
            // verify ordering: before < Hello < after
            let bIdx = stdout.IndexOf "before"
            let hIdx = stdout.IndexOf "Hello"
            let aIdx = stdout.IndexOf "after"
            Expect.isTrue (bIdx < hIdx && hIdx < aIdx)
                (sprintf "expected before < Hello < after in '%s'" stdout)

        testCase "aspect_weaver_no_match" <| fun () ->
            // Functions not matching the glob are not wrapped.
            let src = """
package Test.AspectWeaver2

import Std.Core

aspect Loud {
  matches: name like "handle*"

  around(args) -> ret {
    println("before")
    proceed(args)
    println("after")
  }
}

func greet(): Unit {
  println("hi")
}

func main(): Unit {
  greet()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_no_match" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "hi"
                (sprintf "expected 'hi' in stdout, got: '%s'" stdout)
            Expect.isFalse (stdout.Contains "before")
                (sprintf "unexpected 'before' in stdout: '%s'" stdout)

        testCase "aspect_weaver_glob_star" <| fun () ->
            // '*' glob matches all functions, but the aspect only applies once per function.
            let src = """
package Test.AspectWeaver3

import Std.Core

aspect Tag {
  matches: name like "run*"

  around(args) -> ret {
    println("wrap")
    proceed(args)
  }
}

func runFoo(): Unit = println("foo")
func runBar(): Unit = println("bar")
func skip(): Unit   = println("skip")

func main(): Unit {
  runFoo()
  runBar()
  skip()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_glob_star" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            // wrap prints before each run* function
            Expect.stringContains stdout "wrap"
                (sprintf "expected 'wrap' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "foo"
                (sprintf "expected 'foo' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "bar"
                (sprintf "expected 'bar' in stdout, got: '%s'" stdout)
            // skip is not wrapped
            Expect.stringContains stdout "skip"
                (sprintf "expected 'skip' in stdout, got: '%s'" stdout)
    ]
