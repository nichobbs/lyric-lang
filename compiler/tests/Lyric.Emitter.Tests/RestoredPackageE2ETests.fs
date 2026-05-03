/// End-to-end smoke test for the build-time consumer of restored
/// Lyric packages (D-progress-077 follow-up).  Builds a fake
/// `Lyric.Greeter` package, drops its DLL into a temp NuGet cache
/// layout, then compiles + runs a consumer program that imports
/// from it via the standard `import Lyric.Greeter` flow.
module Lyric.Emitter.Tests.RestoredPackageE2ETests

open System
open System.IO
open Expecto
open Lyric.Emitter.Emitter
open Lyric.Emitter.RestoredPackages
open Lyric.Emitter.Tests.EmitTestKit

let private guidDir (prefix: string) : string =
    let dir = Path.Combine(Path.GetTempPath(),
                            prefix + "-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory dir |> ignore
    dir

/// Compile a Lyric package source string into a `.dll` in `outDir`.
/// Returns the absolute path on success; raises on diagnostics.
let private buildPackage (outDir: string) (name: string) (source: string) : string =
    let dll = Path.Combine(outDir, name + ".dll")
    let req : EmitRequest =
        { Source           = source
          AssemblyName     = name
          OutputPath       = dll
          RestoredPackages = [] }
    let r = emit req
    let errs =
        r.Diagnostics
        |> List.filter (fun d -> d.Severity = Lyric.Lexer.DiagError)
    if not (List.isEmpty errs) then
        failwithf "buildPackage '%s' failed: %A" name errs
    dll

let tests =
    testList "Lyric.Emitter.RestoredPackageE2E" [

        testCase "consumer imports + calls a restored Lyric package" <| fun () ->
            // 1. Build the producer package.  The contract resource is
            //    embedded automatically by the emitter (D-progress-031).
            let pkgBuild = guidDir "lyric-rp-producer"
            let producerDll =
                buildPackage pkgBuild "Lyric.Greeter" """
package Lyric.Greeter

pub func greet(name: in String): String = name

func main(): Unit { ()  }
"""

            // 2. Stage the DLL under a fake NuGet cache layout
            //    (lowercase pkg dir; nested lib/net10.0/<name>.dll).
            let nugetRoot = guidDir "lyric-rp-nuget"
            let restoredLib =
                Path.Combine(
                    nugetRoot,
                    "lyric.greeter",
                    "0.1.0",
                    "lib",
                    "net10.0")
            Directory.CreateDirectory restoredLib |> ignore
            let restoredDll = Path.Combine(restoredLib, "Lyric.Greeter.dll")
            File.Copy(producerDll, restoredDll, overwrite = true)

            // 3. Build + run the consumer program with the restored
            //    package wired through `EmitRequest.RestoredPackages`.
            //    The consumer's `import Lyric.Greeter` resolves to the
            //    restored DLL via the new resolveRestoredImports path.
            let consumerDir = prepareOutputDir "rp-consumer"
            // Copy the restored DLL into the consumer's output dir so
            // the .NET probing finds it when `dotnet exec`-ing.
            File.Copy(
                restoredDll,
                Path.Combine(consumerDir, "Lyric.Greeter.dll"),
                overwrite = true)
            let consumerDll = Path.Combine(consumerDir, "rp-consumer.dll")
            let req : EmitRequest =
                { Source =
                    """
package Demo

import Lyric.Greeter

func main(): Unit {
  println(greet("world"))
}
"""
                  AssemblyName     = "rp-consumer"
                  OutputPath       = consumerDll
                  RestoredPackages =
                    [ { Name    = "Lyric.Greeter"
                        Version = "0.1.0"
                        DllPath = restoredDll } ] }
            let result = emit req
            let errs =
                result.Diagnostics
                |> List.filter (fun d -> d.Severity = Lyric.Lexer.DiagError)
            Expect.isEmpty errs
                (sprintf "consumer build had errors: %A" errs)
            Expect.isSome result.OutputPath "consumer produced an output PE"

            let stdout, stderr, exitCode = runDll consumerDll
            Expect.equal exitCode 0
                (sprintf "consumer exited %d (stderr=%s)" exitCode stderr)
            Expect.equal (stdout.TrimEnd()) "world"
                "consumer printed greet's output"

        testCase "missing restored package surfaces E901 with helpful message" <| fun () ->
            // No DLL ever placed at this path — the resolver should
            // surface a structured `E901` error rather than crashing.
            let req : EmitRequest =
                { Source =
                    """
package Demo

import Lyric.Greeter

func main(): Unit { () }
"""
                  AssemblyName     = "rp-missing"
                  OutputPath       = Path.Combine(Path.GetTempPath(),
                                                  "lyric-rp-missing.dll")
                  RestoredPackages =
                    [ { Name    = "Lyric.Greeter"
                        Version = "0.1.0"
                        DllPath = "/this/does/not/exist.dll" } ] }
            let result = emit req
            let codes = result.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "E901" "missing-restored-DLL surfaces E901"
            Expect.isNone result.OutputPath
                "no output when restored-package load fails"
    ]
