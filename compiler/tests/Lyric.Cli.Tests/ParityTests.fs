/// Cross-platform parity smoke-test suite (docs/33-platform-parity-remediation.md §7).
///
/// Verifies that 20 Lyric programs produce identical stdout through all three
/// compilation paths:
///   - dotnet-legacy : F# emitter (Lyric.Emitter) — the escape-hatch baseline.
///   - dotnet        : self-hosted MSIL bridge (SelfHostedMsil.compileToDll).
///   - jvm           : self-hosted JVM bridge (SelfHostedJvm.compileToJar).
///
/// Programs are restricted to the common subset of all three paths:
/// primitive types (Int, Bool, String), top-level main, arithmetic,
/// boolean logic, comparisons, if/else, while/break/continue,
/// match on literals and bindings, string concatenation.
/// No records, unions, user-defined function calls, contracts, or imports —
/// these avoid the return-type approximation limitations of the bootstrap
/// self-hosted codegens.
module Lyric.Cli.Tests.ParityTests

open System
open System.IO
open System.Diagnostics
open Expecto
open Lyric.Lexer
open Lyric.Cli
open Lyric.Emitter

// ─── runtime helpers ──────────────────────────────────────────────────────────

let private dotnetHost () =
    match Option.ofObj (Environment.GetEnvironmentVariable "DOTNET_HOST_PATH") with
    | Some p when File.Exists p -> p
    | _ ->
        let p = "/root/.dotnet/dotnet"
        if File.Exists p then p else "dotnet"

let private javaExe () =
    let p = "/usr/bin/java"
    if File.Exists p then p else "java"

let private runProcess (exe: string) (args: string list) : string * string * int =
    let psi = ProcessStartInfo()
    psi.FileName <- exe
    for a in args do psi.ArgumentList.Add a
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.UseShellExecute         <- false
    psi.CreateNoWindow          <- true
    let proc =
        match Option.ofObj (Process.Start psi) with
        | Some p -> p
        | None   -> failwithf "failed to start %s" exe
    use _ = proc
    let stdoutTask = System.Threading.Tasks.Task.Run(fun () -> proc.StandardOutput.ReadToEnd())
    let stderrTask = System.Threading.Tasks.Task.Run(fun () -> proc.StandardError.ReadToEnd())
    let exited = proc.WaitForExit(60_000)
    if not exited then
        try proc.Kill() with _ -> ()
        proc.WaitForExit()
    stdoutTask.Result, stderrTask.Result, proc.ExitCode

let private runDll (dll: string) : string * string * int =
    runProcess (dotnetHost ()) ["exec"; dll]

let private runJar (jar: string) : string * string * int =
    runProcess (javaExe ()) ["-jar"; jar]

// ─── dotnet-legacy path (F# emitter) ──────────────────────────────────────────

let private copyStdlibDlls (outDir: string) : unit =
    for p in Emitter.stdlibAssemblyPaths () do
        if File.Exists p then
            let fname =
                match Option.ofObj (Path.GetFileName p) with
                | Some f -> f
                | None   -> "Lyric.Stdlib.Core.dll"
            File.Copy(p, Path.Combine(outDir, fname), overwrite = true)

let private writeRuntimeConfig (dllPath: string) : unit =
    let v = Environment.Version
    let configPath =
        match Option.ofObj (Path.ChangeExtension(dllPath, ".runtimeconfig.json")) with
        | Some p -> p
        | None   -> dllPath + ".runtimeconfig.json"
    File.WriteAllText(
        configPath,
        sprintf
            "{\n  \"runtimeOptions\": {\n    \"tfm\": \"net%d.%d\",\n    \"framework\": {\n      \"name\": \"Microsoft.NETCore.App\",\n      \"version\": \"%s\"\n    }\n  }\n}\n"
            v.Major v.Minor (v.ToString()))

let private compileAndRunLegacy (label: string) (source: string) : string =
    let dir =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-parity-legacy-%s-%s" label (Guid.NewGuid().ToString "N"))
    Directory.CreateDirectory dir |> ignore
    try
        let dll = Path.Combine(dir, label + ".dll")
        let req : Emitter.EmitRequest =
            { Source             = source
              AssemblyName       = label
              OutputPath         = dll
              RestoredPackages   = []
              NugetAssemblyPaths = []
              ExternShimRoot     = None
              Target             = Emitter.Dotnet
              ActiveFeatures     = Set.empty
              DeclaredFeatures   = Set.empty }
        let result = Emitter.emit req
        copyStdlibDlls dir
        let fsharp = Path.Combine(AppContext.BaseDirectory, "FSharp.Core.dll")
        if File.Exists fsharp then
            File.Copy(fsharp, Path.Combine(dir, "FSharp.Core.dll"), overwrite = true)
        writeRuntimeConfig dll
        let errs =
            result.Diagnostics |> List.filter (fun d -> d.Severity = DiagError)
        if not (List.isEmpty errs) then
            failwithf "legacy compile errors: %s"
                (errs |> List.map (fun d -> d.Message) |> String.concat "; ")
        let stdout, stderr, exitCode = runDll dll
        if exitCode <> 0 then
            failwithf "legacy runtime error (exit %d): %s" exitCode stderr
        stdout.TrimEnd()
    finally
        try Directory.Delete(dir, recursive = true) with _ -> ()

// ─── dotnet path (self-hosted MSIL bridge) ────────────────────────────────────

let private compileAndRunMsil (label: string) (source: string) : string =
    let dir =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-parity-msil-%s-%s" label (Guid.NewGuid().ToString "N"))
    Directory.CreateDirectory dir |> ignore
    try
        let dll = Path.Combine(dir, label + ".dll")
        let ok = SelfHostedMsil.compileToDll source dll
        if not ok then
            failwithf "self-hosted MSIL compile failed for '%s'" label
        let stdout, stderr, exitCode = runDll dll
        if exitCode <> 0 then
            failwithf "MSIL runtime error (exit %d): %s" exitCode stderr
        stdout.TrimEnd()
    finally
        try Directory.Delete(dir, recursive = true) with _ -> ()

// ─── jvm path (self-hosted JVM bridge) ───────────────────────────────────────

let private compileAndRunJvm (label: string) (pkgName: string) (source: string) : string =
    let dir =
        Path.Combine(Path.GetTempPath(),
                     sprintf "lyric-parity-jvm-%s-%s" label (Guid.NewGuid().ToString "N"))
    Directory.CreateDirectory dir |> ignore
    try
        let jar = Path.Combine(dir, label + ".jar")
        let ok = SelfHostedJvm.compileToJar source jar pkgName
        if not ok then
            failwithf "self-hosted JVM compile failed for '%s'" label
        let stdout, stderr, exitCode = runJar jar
        if exitCode <> 0 then
            failwithf "JVM runtime error (exit %d): %s" exitCode stderr
        stdout.TrimEnd()
    finally
        try Directory.Delete(dir, recursive = true) with _ -> ()

// ─── test builder ─────────────────────────────────────────────────────────────

/// Produce three sequenced test cases for one parity program.
let private mkParity
        (label: string) (pkgName: string)
        (source: string) (expected: string)
        : Test list =
    [ testCase (sprintf "[%s] dotnet-legacy" label) <| fun () ->
          Expect.equal (compileAndRunLegacy label source) expected
              (sprintf "dotnet-legacy output for '%s'" label)

      testCase (sprintf "[%s] dotnet" label) <| fun () ->
          Expect.equal (compileAndRunMsil label source) expected
              (sprintf "dotnet output for '%s'" label)

      testCase (sprintf "[%s] jvm" label) <| fun () ->
          Expect.equal (compileAndRunJvm label pkgName source) expected
              (sprintf "jvm output for '%s'" label) ]

// ─── 20 parity programs ───────────────────────────────────────────────────────
//
// Each entry: (label, JVM package name, Lyric source, expected stdout).
//
// All programs share the common subset of all three paths:
//   • No user-defined function calls (self-hosted codegens approximate return
//     type as Object; println would dispatch to the wrong overload).
//   • No record/union construction (bootstrap-grade codegen).
//   • No imports (beyond the built-in println/toString wiring).
//   • Booleans rendered via if/else — .NET prints "True"/"False",
//     JVM prints "true"/"false"; string literals avoid the discrepancy.

let private parityPrograms : (string * string * string * string) list =
  [ ("parity01_hello", "Parity01Hello",
     "package Parity01Hello\nfunc main(): Unit { println(\"hello parity\") }\n",
     "hello parity")

    ("parity02_add", "Parity02Add",
     "package Parity02Add\nfunc main(): Unit { println(3 + 4) }\n",
     "7")

    ("parity03_sub", "Parity03Sub",
     "package Parity03Sub\nfunc main(): Unit { println(10 - 3) }\n",
     "7")

    ("parity04_mul", "Parity04Mul",
     "package Parity04Mul\nfunc main(): Unit { println(6 * 7) }\n",
     "42")

    ("parity05_div", "Parity05Div",
     "package Parity05Div\nfunc main(): Unit { println(17 / 4) }\n",
     "4")

    ("parity06_mod", "Parity06Mod",
     "package Parity06Mod\nfunc main(): Unit { println(17 % 4) }\n",
     "1")

    ("parity07_neg", "Parity07Neg",
     "package Parity07Neg\nfunc main(): Unit { println(0 - 5) }\n",
     "-5")

    ("parity08_bool_and", "Parity08BoolAnd",
     "package Parity08BoolAnd\nfunc main(): Unit {\n  if true and false { println(\"true\") } else { println(\"false\") }\n}\n",
     "false")

    ("parity09_bool_or", "Parity09BoolOr",
     "package Parity09BoolOr\nfunc main(): Unit {\n  if false or true { println(\"true\") } else { println(\"false\") }\n}\n",
     "true")

    ("parity10_bool_not", "Parity10BoolNot",
     "package Parity10BoolNot\nfunc main(): Unit {\n  if not true { println(\"true\") } else { println(\"false\") }\n}\n",
     "false")

    ("parity11_if_true", "Parity11IfTrue",
     "package Parity11IfTrue\nfunc main(): Unit {\n  if 3 > 2 { println(\"yes\") } else { println(\"no\") }\n}\n",
     "yes")

    ("parity12_if_false", "Parity12IfFalse",
     "package Parity12IfFalse\nfunc main(): Unit {\n  if 2 > 3 { println(\"yes\") } else { println(\"no\") }\n}\n",
     "no")

    ("parity13_while_count", "Parity13WhileCount",
     "package Parity13WhileCount\nfunc main(): Unit {\n  var i = 0\n  while i < 5 { i = i + 1 }\n  println(i)\n}\n",
     "5")

    ("parity14_while_break", "Parity14WhileBreak",
     "package Parity14WhileBreak\nfunc main(): Unit {\n  var i = 0\n  while i < 100 {\n    if i == 5 { break }\n    i = i + 1\n  }\n  println(i)\n}\n",
     "5")

    ("parity15_while_continue", "Parity15WhileContinue",
     "package Parity15WhileContinue\nfunc main(): Unit {\n  var i = 0\n  var sum = 0\n  while i < 10 {\n    i = i + 1\n    if i % 2 == 0 { continue }\n    sum = sum + i\n  }\n  println(sum)\n}\n",
     "25")

    ("parity16_while_nested", "Parity16WhileNested",
     "package Parity16WhileNested\nfunc main(): Unit {\n  var total = 0\n  var i = 0\n  while i < 5 {\n    var j = 0\n    while j < 3 {\n      total = total + 1\n      j = j + 1\n    }\n    i = i + 1\n  }\n  println(total)\n}\n",
     "15")

    ("parity17_val_chain", "Parity17ValChain",
     "package Parity17ValChain\nfunc main(): Unit {\n  val a = 10\n  val b = 20\n  val c = a + b\n  println(c)\n}\n",
     "30")

    ("parity18_match_int", "Parity18MatchInt",
     "package Parity18MatchInt\nfunc main(): Unit {\n  val x = 2\n  match x {\n    case 1 -> println(\"one\")\n    case 2 -> println(\"two\")\n    case _ -> println(\"other\")\n  }\n}\n",
     "two")

    ("parity19_match_bind", "Parity19MatchBind",
     "package Parity19MatchBind\nfunc main(): Unit {\n  val x = 42\n  match x {\n    case n -> println(n)\n  }\n}\n",
     "42")

    ("parity20_str_concat", "Parity20StrConcat",
     "package Parity20StrConcat\nfunc main(): Unit { println(\"hello\" + \" \" + \"world\") }\n",
     "hello world") ]

// ─── test list ────────────────────────────────────────────────────────────────

let tests =
    testSequenced
    <| testList "Parity smoke-tests (dotnet-legacy / dotnet / jvm)" [
        for label, pkgName, source, expected in parityPrograms do
            yield! mkParity label pkgName source expected
    ]
