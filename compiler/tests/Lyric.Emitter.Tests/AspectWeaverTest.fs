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

        testCase "aspect_weaver_no_aspect_all" <| fun () ->
            // @no_aspect (no arg) opts the function out of all aspects.
            let src = """
package Test.NoAspectAll

import Std.Core

aspect Loud {
  matches: name like "greet*"

  around(args) -> ret {
    println("before")
    proceed(args)
    println("after")
  }
}

func greet(): Unit {
  println("hi")
}

@no_aspect
func greetAdmin(): Unit {
  println("admin")
}

func main(): Unit {
  greet()
  greetAdmin()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_no_aspect_all" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            // greet() is wrapped
            Expect.stringContains stdout "before"
                (sprintf "expected 'before' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "hi"
                (sprintf "expected 'hi' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "after"
                (sprintf "expected 'after' in stdout, got: '%s'" stdout)
            // greetAdmin() is NOT wrapped
            Expect.stringContains stdout "admin"
                (sprintf "expected 'admin' in stdout, got: '%s'" stdout)
            let adminIdx = stdout.IndexOf "admin"
            let beforeCount = stdout.Split("before").Length - 1
            Expect.equal beforeCount 1
                (sprintf "expected exactly one 'before' (admin should not be wrapped), got stdout: '%s'" stdout)

        testCase "aspect_weaver_no_aspect_named" <| fun () ->
            // @no_aspect("AspectName") opts out of just that aspect.
            let src = """
package Test.NoAspectNamed

import Std.Core

aspect Loud {
  matches: name like "greet*"

  around(args) -> ret {
    println("before")
    proceed(args)
    println("after")
  }
}

func greet(): Unit {
  println("hi")
}

@no_aspect("Loud")
func greetQuiet(): Unit {
  println("quiet")
}

func main(): Unit {
  greet()
  greetQuiet()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_no_aspect_named" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            // greet() is wrapped
            Expect.stringContains stdout "before" (sprintf "stdout: '%s'" stdout)
            Expect.stringContains stdout "hi"     (sprintf "stdout: '%s'" stdout)
            Expect.stringContains stdout "after"  (sprintf "stdout: '%s'" stdout)
            // greetQuiet() is NOT wrapped (opted out by name)
            Expect.stringContains stdout "quiet"  (sprintf "stdout: '%s'" stdout)
            Expect.equal (stdout.Split("before").Length - 1) 1
                (sprintf "greetQuiet should not be wrapped, stdout: '%s'" stdout)
    ]
