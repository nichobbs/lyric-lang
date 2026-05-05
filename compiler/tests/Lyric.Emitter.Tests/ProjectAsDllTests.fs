/// Tests for project-as-DLL emit (M5.1 stage 2c.2.ii).
///
/// `emitProject` takes a list of per-package source feeds plus a
/// bundled-DLL output path; it parses, type-checks, and emits each
/// package into ONE shared `PersistedAssemblyBuilder` and embeds
/// `Lyric.Contract.<Pkg>` resources for downstream consumers.
///
/// The MVP scope (this PR) is "independent packages bundle into one
/// DLL with separate per-package contract resources".  Cross-package
/// imports within the same project are not yet wired — each package
/// still resolves imports through the existing per-package import
/// surface.
module Lyric.Emitter.Tests.ProjectAsDllTests

open System
open System.IO
open Expecto
open Lyric.Emitter
open Lyric.Lexer
open Lyric.Emitter.Tests.EmitTestKit

let private withTempDll (label: string) (action: string -> 'a) : 'a =
    let dir =
        Path.Combine(
            Path.GetTempPath(),
            "lyric-projectdll-" + label + "-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory(dir) |> ignore
    // Stage the stdlib next to the bundled DLL so any `import Std.*`
    // imports resolve at runtime.  Mirrors `prepareOutputDir` in
    // EmitTestKit but keyed off the project test name.
    let stdlibDll =
        Path.Combine(AppContext.BaseDirectory, "Lyric.Stdlib.dll")
    if File.Exists stdlibDll then
        File.Copy(stdlibDll, Path.Combine(dir, "Lyric.Stdlib.dll"), overwrite = true)
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

let tests =
    testSequenced
    <| testList "project-as-DLL emit (M5.1 stage 2c.2.ii)" [

        // Two independent packages compile into ONE bundled DLL with
        // two `Lyric.Contract.<Pkg>` resources.  Neither package
        // imports the other (cross-package symbol resolution within
        // the project is deferred to stage 2c.2.ii.b).
        testCase "[two_packages_bundle_into_one_dll]" <| fun () ->
            withTempDll "two-pkgs" <| fun dir ->
                let dllPath = Path.Combine(dir, "MyApp.dll")
                let coreSrc =
                    "package MyApp.Core\n" +
                    "@stable(since=\"0.1\")\n" +
                    "pub func double(x: in Int): Int { x + x }\n"
                let utilSrc =
                    "package MyApp.Util\n" +
                    "@stable(since=\"0.1\")\n" +
                    "pub func square(x: in Int): Int { x * x }\n"
                let req : Emitter.ProjectEmitRequest =
                    { Packages =
                        [ { PackageName = "MyApp.Core"
                            Sources     = [coreSrc] }
                          { PackageName = "MyApp.Util"
                            Sources     = [utilSrc] } ]
                      AssemblyName     = "MyApp"
                      OutputPath       = dllPath
                      RestoredPackages = []
                      Single           = true }
                let result = Emitter.emitProject req
                let errs =
                    result.Diagnostics
                    |> List.filter (fun d ->
                        d.Severity = DiagError
                        && (d.Code.StartsWith "E"
                            || d.Code.StartsWith "T"
                            || d.Code.StartsWith "P"
                            || d.Code.StartsWith "B"))
                Expect.isEmpty errs
                    (sprintf "expected no errors (got %A)" errs)
                Expect.equal result.OutputPath (Some dllPath) "OutputPath"
                Expect.isTrue (File.Exists dllPath)
                    (sprintf "bundled DLL %s should exist" dllPath)
                // Both per-package contract resources should be in
                // the bundle, neither under the legacy `Lyric.Contract`
                // single name.
                let contracts =
                    ContractMeta.readAllContractsFromAssembly dllPath
                let pkgs = contracts |> List.map fst |> List.sort
                Expect.equal pkgs ["MyApp.Core"; "MyApp.Util"]
                    "both per-package contracts present"
                let coreJson =
                    contracts
                    |> List.find (fun (p, _) -> p = "MyApp.Core")
                    |> snd
                Expect.stringContains coreJson "double"
                    "Core contract names `double`"
                let utilJson =
                    contracts
                    |> List.find (fun (p, _) -> p = "MyApp.Util")
                    |> snd
                Expect.stringContains utilJson "square"
                    "Util contract names `square`"
                // Legacy single-resource form must NOT also appear.
                Expect.equal
                    (ContractMeta.readFromAssembly dllPath)
                    None
                    "legacy `Lyric.Contract` resource absent for projects"

        // B0023 — `output = "single"` with zero packages.
        testCase "[B0023_zero_packages]" <| fun () ->
            withTempDll "b0023" <| fun dir ->
                let dllPath = Path.Combine(dir, "Empty.dll")
                let req : Emitter.ProjectEmitRequest =
                    { Packages         = []
                      AssemblyName     = "Empty"
                      OutputPath       = dllPath
                      RestoredPackages = []
                      Single           = true }
                let result = Emitter.emitProject req
                let b0023 =
                    result.Diagnostics
                    |> List.filter (fun d -> d.Code = "B0023")
                Expect.isNonEmpty b0023 "B0023 raised"
                Expect.equal result.OutputPath None
                    "no bundled DLL produced on B0023"
    ]
