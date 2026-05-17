/// Aspect weaver A1/A2/A3/A4 — wrapper synthesis, @no_aspect, contract augmentation, multi-aspect ordering.
module Lyric.Emitter.Tests.AspectWeaverTest

open Expecto
open Lyric.Emitter.Tests.EmitTestKit

let tests =
    testList "Aspect Weaver A1-A4 (wrapper synthesis, @no_aspect, contracts, ordering)" [

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

        testCase "aspect_weaver_contract_augmentation" <| fun () ->
            // §5: requires: on the aspect body is parsed and composed into the wrapper.
            // A trivially-true requires: should not break compilation or runtime.
            let src = """
package Test.ContractAugment

import Std.Core

aspect Positive {
  matches: name like "add*"
  requires: true

  around(args) -> ret {
    proceed(args)
  }
}

func add(x: in Int, y: in Int): Int {
  return x + y
}

func main(): Unit {
  val r = add(3, 4)
  println(r)
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_contract_augmentation" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "7"
                (sprintf "expected '7' in stdout, got: '%s'" stdout)

        testCase "aspect_weaver_contract_on_wrapper" <| fun () ->
            // The aspect's requires: clause appears on the wrapper and is parsed
            // without errors. The simplest verification is that the program compiles
            // and runs correctly — contract parse/compose correctness.
            let src = """
package Test.ContractOnWrapper

import Std.Core

aspect Guard {
  matches: name like "compute*"
  requires: true

  around(args) -> ret {
    proceed(args)
  }
}

func compute(n: in Int): Int {
  return n * 2
}

func main(): Unit {
  println(compute(5))
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_contract_on_wrapper" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "10"
                (sprintf "expected '10' in stdout, got: '%s'" stdout)

        testCase "aspect_weaver_multi_ordering" <| fun () ->
            // §6: two aspects with wraps: ordering — Outer wraps Inner.
            // Expected call chain: public(=Outer) → __aspect_Inner → __aspect_target.
            // Verifies output ordering: outer-start, inner-start, body, inner-end, outer-end.
            let src = """
package Test.MultiOrder

import Std.Core

aspect Inner {
  matches: name like "compute*"

  around(args) -> ret {
    println("inner-start")
    proceed(args)
    println("inner-end")
  }
}

aspect Outer {
  matches: name like "compute*"
  wraps: Inner

  around(args) -> ret {
    println("outer-start")
    proceed(args)
    println("outer-end")
  }
}

func compute(): Unit {
  println("body")
}

func main(): Unit {
  compute()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_multi_ordering" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            let lines = stdout.Trim().Split('\n') |> Array.map (fun s -> s.Trim()) |> Array.filter (fun s -> s.Length > 0)
            Expect.equal lines [| "outer-start"; "inner-start"; "body"; "inner-end"; "outer-end" |]
                (sprintf "unexpected output order, stdout: '%s'" stdout)

        testCase "aspect_weaver_proceed_in_loop" <| fun () ->
            // Regression: proceed(args) inside a while loop in the around body must be rewritten.
            // buildWrapper.rwStmt previously dropped loop bodies without recursing, leaving proceed
            // as an unresolved name; the fix delegates to rewriteProceeds which is fully recursive.
            let src = """
package Test.ProceedInLoop

import Std.Core

aspect Repeat {
  matches: name like "greet"

  around(args) -> ret {
    var i = 0
    while i < 3 {
      proceed(args)
      i = i + 1
    }
  }
}

func greet(): Unit {
  println("hi")
}

func main(): Unit {
  greet()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_proceed_in_loop" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            let lines = stdout.Trim().Split('\n') |> Array.map (fun s -> s.Trim()) |> Array.filter (fun s -> s.Length > 0)
            Expect.equal lines [| "hi"; "hi"; "hi" |]
                (sprintf "expected 3x 'hi', got: '%s'" stdout)

        testCase "aspect_weaver_annotated_predicate" <| fun () ->
            // `annotated: @instrument` matches functions carrying that annotation;
            // unannotated functions are not wrapped.
            let src = """
package Test.AnnotatedPredicate

import Std.Core

aspect Trace {
  matches: annotated: @instrument

  around(args) -> ret {
    println("traced")
    proceed(args)
  }
}

@instrument
func doWork(): Unit {
  println("work")
}

func skip(): Unit {
  println("skip")
}

func main(): Unit {
  doWork()
  skip()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_annotated_predicate" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "traced"
                (sprintf "expected 'traced' (doWork is annotated), got: '%s'" stdout)
            Expect.stringContains stdout "work"
                (sprintf "expected 'work' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "skip"
                (sprintf "expected 'skip' in stdout, got: '%s'" stdout)
            // skip() is not @instrument, so 'traced' appears only once
            Expect.equal (stdout.Split("traced").Length - 1) 1
                (sprintf "expected exactly one 'traced' (skip should not be wrapped), got stdout: '%s'" stdout)

        testCase "aspect_weaver_visibility_predicate" <| fun () ->
            // `visibility: pub` matches only public functions.
            let src = """
package Test.VisibilityPredicate

import Std.Core

aspect PubOnly {
  matches: visibility: pub

  around(args) -> ret {
    println("pub-wrap")
    proceed(args)
  }
}

pub func publicFn(): Unit {
  println("public")
}

func privateFn(): Unit {
  println("private")
}

func main(): Unit {
  publicFn()
  privateFn()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_visibility_predicate" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "pub-wrap"
                (sprintf "expected 'pub-wrap' (publicFn is pub), got: '%s'" stdout)
            Expect.stringContains stdout "public"
                (sprintf "expected 'public' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "private"
                (sprintf "expected 'private' in stdout, got: '%s'" stdout)
            // privateFn is not matched, so 'pub-wrap' appears exactly once
            Expect.equal (stdout.Split("pub-wrap").Length - 1) 1
                (sprintf "expected exactly one 'pub-wrap', got stdout: '%s'" stdout)

        testCase "aspect_weaver_signature_returns_predicate" <| fun () ->
            // `signature: returns Int` matches functions that return Int.
            let src = """
package Test.SignatureReturnsPredicate

import Std.Core

aspect IntReturn {
  matches: signature: returns "Int"

  around(args) -> ret {
    println("int-wrap")
    proceed(args)
  }
}

func getNumber(): Int {
  return 42
}

func getText(): String {
  return "hello"
}

func main(): Unit {
  println(getNumber())
  println(getText())
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_signature_returns_predicate" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "int-wrap"
                (sprintf "expected 'int-wrap' (getNumber returns Int), got: '%s'" stdout)
            Expect.stringContains stdout "42"
                (sprintf "expected '42' in stdout, got: '%s'" stdout)
            Expect.stringContains stdout "hello"
                (sprintf "expected 'hello' in stdout, got: '%s'" stdout)
            // getText returns String, not Int — should not be wrapped
            Expect.equal (stdout.Split("int-wrap").Length - 1) 1
                (sprintf "expected exactly one 'int-wrap', got stdout: '%s'" stdout)

        testCase "aspect_weaver_compound_predicate_and" <| fun () ->
            // `name like "do*" and visibility: pub` — both must hold.
            // publicDo is pub + name matches → wrapped.
            // privateDo is not pub → not wrapped.
            // publicOther is pub but name doesn't match → not wrapped.
            let src = """
package Test.CompoundPredicate

import Std.Core

aspect Selective {
  matches:
    name like "do*"
    and visibility: pub

  around(args) -> ret {
    println("selected")
    proceed(args)
  }
}

pub func doPublic(): Unit {
  println("do-public")
}

func doPrivate(): Unit {
  println("do-private")
}

pub func other(): Unit {
  println("other")
}

func main(): Unit {
  doPublic()
  doPrivate()
  other()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_compound_predicate_and" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "selected"
                (sprintf "expected 'selected' (doPublic matches both predicates), got: '%s'" stdout)
            Expect.stringContains stdout "do-public"  (sprintf "stdout: '%s'" stdout)
            Expect.stringContains stdout "do-private" (sprintf "stdout: '%s'" stdout)
            Expect.stringContains stdout "other"      (sprintf "stdout: '%s'" stdout)
            // Only doPublic satisfies both predicates
            Expect.equal (stdout.Split("selected").Length - 1) 1
                (sprintf "expected exactly one 'selected', got stdout: '%s'" stdout)

        testCase "aspect_weaver_except_clause" <| fun () ->
            // `name like "handle*" except name in { handlePing }` — handlePing is excluded.
            let src = """
package Test.ExceptClause

import Std.Core

aspect Log {
  matches:
    name like "handle*"
    except name in { handlePing }

  around(args) -> ret {
    println("logged")
    proceed(args)
  }
}

func handleRequest(): Unit {
  println("request")
}

func handlePing(): Unit {
  println("ping")
}

func main(): Unit {
  handleRequest()
  handlePing()
}
"""
            let r, stdout, stderr, exitCode = compileAndRun "aspect_weaver_except_clause" src
            let errors = r.Diagnostics |> List.filter (fun d -> d.Code.StartsWith "E" || d.Code.StartsWith "T")
            Expect.isEmpty errors (sprintf "compile errors: %A" (errors |> List.map (fun d -> sprintf "%s: %s" d.Code d.Message)))
            Expect.equal exitCode 0 (sprintf "expected exit 0, stderr=%s stdout=%s" stderr stdout)
            Expect.stringContains stdout "logged"
                (sprintf "expected 'logged' (handleRequest is matched), got: '%s'" stdout)
            Expect.stringContains stdout "request" (sprintf "stdout: '%s'" stdout)
            Expect.stringContains stdout "ping"    (sprintf "stdout: '%s'" stdout)
            // handlePing is excluded, so 'logged' appears exactly once
            Expect.equal (stdout.Split("logged").Length - 1) 1
                (sprintf "expected exactly one 'logged' (handlePing excluded), got stdout: '%s'" stdout)
    ]
