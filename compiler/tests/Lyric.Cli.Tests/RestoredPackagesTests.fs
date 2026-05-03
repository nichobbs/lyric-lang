module Lyric.Cli.Tests.RestoredPackagesTests

open System
open System.IO
open Expecto
open Lyric.Lexer
open Lyric.Emitter
open Lyric.Emitter.RestoredPackages

let private tmpDir () : string =
    let dir = Path.Combine(Path.GetTempPath(),
                            "lyric-rp-test-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory dir |> ignore
    dir

/// Compile a Lyric package source into a `.dll` (with the embedded
/// `Lyric.Contract` resource) at `<dir>/<name>.dll`.  Returns the
/// absolute path.  Used by the loader / E2E tests below.
let private buildPackage (dir: string) (name: string) (source: string) : string =
    let dll = Path.Combine(dir, name + ".dll")
    let req : Emitter.EmitRequest =
        { Source           = source
          AssemblyName     = name
          OutputPath       = dll
          RestoredPackages = [] }
    let r = Emitter.emit req
    let errs = r.Diagnostics |> List.filter (fun d -> d.Severity = DiagError)
    if not (List.isEmpty errs) then
        failwithf "buildPackage '%s' failed: %A" name errs
    dll

let tests =
    testList "Lyric.Emitter.RestoredPackages" [

        testCase "synthesiseSource pastes Reprs under a package header" <| fun () ->
            let contract : ContractMeta.Contract =
                { PackageName = "Lyric.Greeter"
                  Version     = "0.1.0"
                  Decls =
                    [ { Kind = "func"; Name = "greet"
                        Repr = "pub func greet(name: in String): String" }
                      { Kind = "interface"; Name = "Sayable"
                        Repr = "pub interface Sayable" } ] }
            let source = synthesiseSource contract
            Expect.stringContains source "package Lyric.Greeter" "package header"
            Expect.stringContains source
                "pub func greet(name: in String): String"
                "function repr verbatim"
            // Interface bodies are appended so the parser accepts them.
            Expect.stringContains source "pub interface Sayable {}" "interface gets {} body"

        testCase "tryLocateRestoredDll honours NUGET_PACKAGES env" <| fun () ->
            let root = tmpDir ()
            let pkgDir = Path.Combine(root, "lyric.greeter", "0.1.0", "lib", "net10.0")
            Directory.CreateDirectory pkgDir |> ignore
            let dll = Path.Combine(pkgDir, "Lyric.Greeter.dll")
            File.WriteAllBytes(dll, [| 0uy |])
            let prior = Environment.GetEnvironmentVariable "NUGET_PACKAGES"
            Environment.SetEnvironmentVariable("NUGET_PACKAGES", root)
            try
                let found = tryLocateRestoredDll "Lyric.Greeter" "0.1.0"
                Expect.equal found (Some dll) "locator picks up the env-var path"
                let missing = tryLocateRestoredDll "Lyric.Missing" "0.0.1"
                Expect.equal missing None "missing package returns None"
            finally
                Environment.SetEnvironmentVariable("NUGET_PACKAGES", prior)

        testCase "loadRestoredPackage round-trips a real Lyric DLL" <| fun () ->
            let dir = tmpDir ()
            // The emit path currently requires a `main` even for
            // library-shaped packages — `IsLibrary = true` on the
            // EmitRequest is a future C8 follow-up.  The synthesised
            // `main` is harmless: publishing-time consumers don't run
            // it, and the contract resource only describes `pub` items.
            let dll =
                buildPackage dir "Lyric.Greeter" """
package Lyric.Greeter

pub func greet(name: in String): String = name

func main(): Unit { ()  }
"""
            let ref' : RestoredPackageRef =
                { Name = "Lyric.Greeter"; Version = "0.1.0"; DllPath = dll }
            match loadRestoredPackage ref' with
            | Error e -> failwithf "expected Ok, got %A" e
            | Ok artifact ->
                Expect.equal artifact.Contract.PackageName "Lyric.Greeter" "pkg name"
                let funcNames =
                    artifact.Contract.Decls
                    |> List.choose (fun d ->
                        if d.Kind = "func" then Some d.Name else None)
                Expect.contains funcNames "greet" "greet listed"
                let hasGreet =
                    artifact.Source.Items
                    |> List.exists (fun it ->
                        match it.Kind with
                        | Lyric.Parser.Ast.IFunc f -> f.Name = "greet"
                        | _ -> false)
                Expect.isTrue hasGreet "synthesised source carries greet"

        testCase "loadRestoredPackage surfaces missing-DLL as a structured error" <| fun () ->
            let bogus : RestoredPackageRef =
                { Name = "Lyric.Nope"; Version = "0.0.0"
                  DllPath = "/this/does/not/exist.dll" }
            match loadRestoredPackage bogus with
            | Error (DllMissing p) ->
                Expect.equal p "/this/does/not/exist.dll" "path"
            | other -> failwithf "expected DllMissing, got %A" other

        testCase "loadRestoredPackage rejects DLL without contract resource" <| fun () ->
            let dir = tmpDir ()
            let dll = Path.Combine(dir, "Plain.dll")
            // Emit a tiny .NET assembly without a Lyric.Contract resource
            // by reusing System.Reflection.Emit's PersistedAssemblyBuilder
            // would be heavy; the simplest alternative is to write a stub
            // file and accept that loadRestoredPackage will surface either
            // NoContractResource (Cecil reads the file) or the underlying
            // BadImage exception.  Skip explicit setup; just point at a
            // non-Lyric DLL the test runner already loads.
            let runtimeDll =
                Path.Combine(
                    System.Runtime.InteropServices.RuntimeEnvironment.GetRuntimeDirectory(),
                    "System.Threading.dll")
            if File.Exists runtimeDll then
                let ref' : RestoredPackageRef =
                    { Name = "System.Threading"; Version = "0.0.0"; DllPath = runtimeDll }
                match loadRestoredPackage ref' with
                | Error (NoContractResource _) -> ()
                | other ->
                    failwithf "expected NoContractResource, got %A" other
    ]
