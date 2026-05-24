/// Regression tests for #1140: cross-package `Result[Option[T]]`
/// `case None -> …` pattern match silently falls through under
/// `emitProject` when the producing package early-returns
/// `Ok(None)`.
///
/// Root cause: at the construction site (`return Ok(None)`),
/// `ctx.ExpectedType` was not pinned to the substituted field
/// type of the surrounding case (`T = Option<String>` for `Ok`),
/// so the inner `None`'s `inferTypeArgsFromReturn` rejected
/// `ctx.ReturnType` (`Result<Option<String>, String>`, arity 2)
/// when checking against its own arity 1 and fell back to `obj`.
/// The producer thus stored `Option<obj>$None` inside an
/// `Option<String>`-typed slot, and the consumer's
/// `isinst Option<String>$None` returned null.
///
/// These tests exercise the bug both in single-file form (so the
/// fix can be verified without standing up `emitProject`) and in
/// a true two-package `emitProject` shape that mirrors the
/// lyric-session scenario described in the issue.
module Lyric.Emitter.Tests.CrossPackageOptionMatchTests

open System
open System.IO
open Expecto
open Lyric.Emitter
open Lyric.Lexer
open Lyric.Emitter.Tests.EmitTestKit

// ──────────────────────────────────────────────────────────────
// Single-file cases — exercise the construction-site fix in
// isolation.  These don't need `emitProject`; the same `Ok(None)`
// inside a `Result[Option[T], E]`-returning function loses the
// `T = String` instantiation under the original codepath.
// ──────────────────────────────────────────────────────────────

let private singleFileCases : (string * string * string) list = [

    // Direct early-return `Ok(None)` followed by a `case None` arm.
    // Pre-fix: `None` constructed as `Option<obj>` so `case None`
    // silently falls through and the `case Some(_)` arm fires (or
    // the match falls off the end).  Post-fix: prints "none".
    "early_return_ok_none_matches_case_none",
    """
package Bug1
import Std.Core

func produce(input: in String): Result[Option[String], String] {
  if input == "empty" {
    return Ok(None)
  }
  return Ok(Some(value = input))
}

func main(): Unit {
  val gr = produce("empty")
  val opt = unwrapResultOr(gr, None)
  match opt {
    case Some(s) -> println("some: " + s)
    case None    -> println("none")
  }
}
""",
    "none"

    // Trailing-expression `Ok(None)` (no explicit `return`) — same
    // construction-site path, different statement shape.
    "trailing_ok_none_matches_case_none",
    """
package Bug2
import Std.Core

func produce(input: in String): Result[Option[String], String] {
  if input == "empty" {
    Ok(None)
  } else {
    Ok(Some(value = input))
  }
}

func main(): Unit {
  val gr = produce("empty")
  val opt = unwrapResultOr(gr, None)
  match opt {
    case Some(s) -> println("some: " + s)
    case None    -> println("none")
  }
}
""",
    "none"

    // `unwrapResultOr(gr, None)`-style call: the `None` literal in
    // the second argument slot needs the generic imported-func
    // arg-emission path to pin `ExpectedType` to the substituted
    // `T = Option<String>` so the literal closes correctly.
    "default_none_arg_to_unwrapResultOr_closes_T",
    """
package Bug3
import Std.Core

func main(): Unit {
  val produced: Result[Option[String], String] = Err(error = "boom")
  val opt = unwrapResultOr(produced, None)
  match opt {
    case Some(s) -> println("some: " + s)
    case None    -> println("none")
  }
}
""",
    "none"

    // Both arms exercised: produce("empty") -> None, produce("x") -> Some.
    "both_some_and_none_round_trip",
    """
package Bug4
import Std.Core

func produce(input: in String): Result[Option[String], String] {
  if input == "empty" {
    return Ok(None)
  }
  return Ok(Some(value = input))
}

func describe(input: in String): String {
  val gr = produce(input)
  val opt = unwrapResultOr(gr, None)
  match opt {
    case Some(s) -> "some: " + s
    case None    -> "none"
  }
}

func main(): Unit {
  println(describe("empty"))
  println(describe("hello"))
}
""",
    "none\nsome: hello"
]

let private mkSingle (label: string, source: string, expected: string) : Test =
    testCase (sprintf "[%s]" label) <| fun () ->
        let _, stdout, stderr, exitCode = compileAndRun label source
        Expect.equal exitCode 0 (sprintf "exit 0 (stderr=%s)" stderr)
        Expect.equal (stdout.TrimEnd()) expected
            (sprintf "stdout matches expected (got %A)" stdout)

// ──────────────────────────────────────────────────────────────
// Two-package `emitProject` regression — closest in-tree
// reproduction of the lyric-session scenario.  The producing
// package early-returns `Ok(None)` from a function returning
// `Result[Option[String], String]`; the consuming package matches
// the extracted `Option[String]` with `case None`.  Pre-fix the
// arm silently falls through.
// ──────────────────────────────────────────────────────────────

let private withTempDll (label: string) (action: string -> 'a) : 'a =
    let dir =
        Path.Combine(
            Path.GetTempPath(),
            "lyric-1140-" + label + "-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    // Stage the precompiled stdlib next to the bundled DLL so
    // `import Std.Core` resolves at runtime.  Mirrors
    // `ProjectAsDllTests.withTempDll`.
    for p in Lyric.Emitter.Emitter.stdlibAssemblyPaths () do
        if File.Exists p then
            let fname =
                match Option.ofObj (Path.GetFileName p) with
                | Some f -> f
                | None   -> "Lyric.Stdlib.Core.dll"
            File.Copy(p, Path.Combine(dir, fname), overwrite = true)
    let fsharpCore =
        Path.Combine(AppContext.BaseDirectory, "FSharp.Core.dll")
    if File.Exists fsharpCore then
        File.Copy(fsharpCore, Path.Combine(dir, "FSharp.Core.dll"), overwrite = true)
    try
        action dir
    finally
        try Directory.Delete(dir, true) with _ -> ()

let private projectTests =
    testList "emitProject — cross-package Result[Option[T]] case None" [

        testCase "[two_package_ok_none_round_trip]" <| fun () ->
            withTempDll "two-pkg" <| fun dir ->
                let dllPath = Path.Combine(dir, "Bug1140.dll")
                // Producer package: exports a `produce` function that
                // early-returns `Ok(None)` for the magic input.
                let producerSrc =
                    "package Bug1140.Producer\n" +
                    "import Std.Core\n" +
                    "\n" +
                    "@stable(since=\"0.1\")\n" +
                    "pub func produce(input: in String): Result[Option[String], String] {\n" +
                    "  if input == \"empty\" {\n" +
                    "    return Ok(None)\n" +
                    "  }\n" +
                    "  return Ok(Some(value = input))\n" +
                    "}\n"
                // Consumer package: imports the producer, calls it,
                // and matches the extracted `Option[String]` with
                // direct `case Some(s)` / `case None` arms.
                let consumerSrc =
                    "package Bug1140.Consumer\n" +
                    "import Std.Core\n" +
                    "import Bug1140.Producer\n" +
                    "\n" +
                    "func describe(input: in String): String {\n" +
                    "  val gr = produce(input)\n" +
                    "  val opt = unwrapResultOr(gr, None)\n" +
                    "  match opt {\n" +
                    "    case Some(s) -> \"some: \" + s\n" +
                    "    case None    -> \"none\"\n" +
                    "  }\n" +
                    "}\n" +
                    "\n" +
                    "func main(): Unit {\n" +
                    "  println(describe(\"empty\"))\n" +
                    "  println(describe(\"hello\"))\n" +
                    "}\n"
                let req : Emitter.ProjectEmitRequest =
                    { Packages =
                        [ { PackageName = "Bug1140.Producer"
                            Sources     = [producerSrc] }
                          { PackageName = "Bug1140.Consumer"
                            Sources     = [consumerSrc] } ]
                      AssemblyName     = "Bug1140"
                      OutputPath       = dllPath
                      RestoredPackages   = []
                      NugetAssemblyPaths = []
                      ExternShimRoot     = None
                      Single             = true
                      Target             = Emitter.Dotnet
                      ActiveFeatures     = Set.empty
                      DeclaredFeatures   = Set.empty }
                let result = Emitter.emitProject req
                let errs =
                    result.Diagnostics
                    |> List.filter (fun d -> d.Severity = DiagError)
                Expect.isEmpty errs
                    (sprintf "expected no errors (got %A)" errs)
                Expect.isTrue (File.Exists dllPath)
                    (sprintf "bundled DLL %s should exist" dllPath)
                let stdout, stderr, exitCode = runDll dllPath
                Expect.equal exitCode 0
                    (sprintf "exit 0 (stderr=%s)" stderr)
                // Pre-fix: stdout would show "some: " (or empty) for
                // the `empty` input because `case None` silently
                // missed.  Post-fix: prints "none\nsome: hello".
                Expect.equal (stdout.TrimEnd()) "none\nsome: hello"
                    (sprintf "case None matched on cross-package Ok(None) (stdout=%A)" stdout)
    ]

let tests =
    testSequenced
    <| testList "#1140 — cross-package Result[Option[T]] case None"
        [ testList "single-file (construction site)"
            (singleFileCases |> List.map mkSingle)
          projectTests ]
