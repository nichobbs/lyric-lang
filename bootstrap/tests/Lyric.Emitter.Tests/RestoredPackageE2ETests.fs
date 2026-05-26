/// End-to-end smoke test for the build-time consumer of restored
/// Lyric packages (D-progress-077 follow-up).  Builds a fake
/// `Lyric.Greeter` package, drops its DLL into a temp NuGet cache
/// layout, then compiles + runs a consumer program that imports
/// from it via the standard `import Lyric.Greeter` flow.
module Lyric.Emitter.Tests.RestoredPackageE2ETests

open System
open System.IO
open Expecto
open Lyric.Emitter
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
        { Source             = source
          AssemblyName       = name
          OutputPath         = dll
          RestoredPackages   = []
          NugetAssemblyPaths = []
          ExternShimRoot     = None
          Target             = Dotnet
          ActiveFeatures     = Set.empty
          DeclaredFeatures   = Set.empty }
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
                  AssemblyName       = "rp-consumer"
                  OutputPath         = consumerDll
                  RestoredPackages   =
                    [ { Name    = "Lyric.Greeter"
                        Version = "0.1.0"
                        DllPath = restoredDll } ]
                  NugetAssemblyPaths = []
                  ExternShimRoot     = None
                  Target             = Dotnet
                  ActiveFeatures     = Set.empty
                  DeclaredFeatures   = Set.empty }
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
                  AssemblyName       = "rp-missing"
                  OutputPath         = Path.Combine(Path.GetTempPath(),
                                                    "lyric-rp-missing.dll")
                  RestoredPackages   =
                    [ { Name    = "Lyric.Greeter"
                        Version = "0.1.0"
                        DllPath = "/this/does/not/exist.dll" } ]
                  NugetAssemblyPaths = []
                  ExternShimRoot     = None
                  Target             = Dotnet
                  ActiveFeatures     = Set.empty
                  DeclaredFeatures   = Set.empty }
            let result = emit req
            let codes = result.Diagnostics |> List.map (fun d -> d.Code)
            Expect.contains codes "E901" "missing-restored-DLL surfaces E901"
            Expect.isNone result.OutputPath
                "no output when restored-package load fails"
            let e901msg =
                result.Diagnostics
                |> List.tryFind (fun d -> d.Code = "E901")
                |> Option.map (fun d -> d.Message)
                |> Option.defaultValue ""
            Expect.stringContains e901msg "/this/does/not/exist.dll"
                "E901 message names the missing DLL path"
            Expect.stringContains e901msg "lyric restore"
                "E901 message suggests running lyric restore"

        // Stage 2c.2.iii — a single restored ref pointing at a
        // bundled (`output = "single"`) DLL exposes every per-package
        // contract.  The consumer can import any of the bundled
        // packages by name and the import resolver matches by package
        // path, not by the dep ref's Name.
        testCase "consumer imports two packages from a bundled DLL" <| fun () ->
            // Build a bundled DLL containing two packages.
            let bundleDir = guidDir "lyric-rp-bundle"
            let bundleDll = Path.Combine(bundleDir, "MyLib.dll")
            let coreSrc =
                "package MyLib.Core\n" +
                "@stable(since=\"0.1\")\n" +
                "pub func double(x: in Int): Int { x + x }\n"
            let utilSrc =
                "package MyLib.Util\n" +
                "@stable(since=\"0.1\")\n" +
                "pub func square(x: in Int): Int { x * x }\n"
            let req : ProjectEmitRequest =
                { Packages =
                    [ { PackageName = "MyLib.Core"; Sources = [coreSrc] }
                      { PackageName = "MyLib.Util"; Sources = [utilSrc] } ]
                  AssemblyName       = "MyLib"
                  OutputPath         = bundleDll
                  RestoredPackages   = []
                  NugetAssemblyPaths = []
                  ExternShimRoot     = None
                  Single             = true
                  Target             = Dotnet
                  ActiveFeatures     = Set.empty
                  DeclaredFeatures   = Set.empty }
            let bundleResult = emitProject req
            let bundleErrs =
                bundleResult.Diagnostics
                |> List.filter (fun d -> d.Severity = Lyric.Lexer.DiagError)
            Expect.isEmpty bundleErrs (sprintf "bundle clean (%A)" bundleErrs)

            // Consumer imports both packages from the bundle via a
            // single restored ref.
            let consumerDir = prepareOutputDir "rp-bundle-consumer"
            File.Copy(
                bundleDll,
                Path.Combine(consumerDir, "MyLib.dll"),
                overwrite = true)
            let consumerDll = Path.Combine(consumerDir, "rp-bundle-consumer.dll")
            let consumerReq : EmitRequest =
                { Source =
                    """
package Demo

import MyLib.Core
import MyLib.Util

func main(): Unit {
  println(toString(double(3)))
  println(toString(square(4)))
}
"""
                  AssemblyName       = "rp-bundle-consumer"
                  OutputPath         = consumerDll
                  RestoredPackages   =
                    [ { Name    = "MyLib"
                        Version = "0.1.0"
                        DllPath = bundleDll } ]
                  NugetAssemblyPaths = []
                  ExternShimRoot     = None
                  Target             = Dotnet
                  ActiveFeatures     = Set.empty
                  DeclaredFeatures   = Set.empty }
            let result = emit consumerReq
            let errs =
                result.Diagnostics
                |> List.filter (fun d -> d.Severity = Lyric.Lexer.DiagError)
            Expect.isEmpty errs (sprintf "consumer clean (%A)" errs)
            Expect.isSome result.OutputPath "consumer produced an output"
            let stdout, stderr, exitCode = runDll consumerDll
            Expect.equal exitCode 0
                (sprintf "consumer exit %d (stderr=%s)" exitCode stderr)
            let nl = System.Environment.NewLine
            Expect.equal (stdout.Trim()) ("6" + nl + "16")
                "consumer printed double(3) then square(4)"

        // F11 / Q021-4 Path 1.5 regression: satisfiesViaImportedDistinct.
        // A cross-package distinct type with a derives clause must satisfy
        // `where T: marker` constraints in the importing package.
        // Known bug: the emitter resolves the imported distinct type as Object
        // instead of Score, so checkBounds rejects it (Codegen.fs:735).
        // The satisfiesViaImportedDistinct path (Codegen.fs:689-693) is not
        // consulted because the type argument is already lost by that point.
        // Pending until the importedDistinctTypes lookup is wired into
        // the call-site type-argument inference.
        ptestCase "Q021-4 Path 1.5: cross-package distinct type satisfies where-clause" <| fun () ->
            // Build a producer package that defines a distinct type with derives.
            let producerDir = guidDir "lyric-rp-q021-producer"
            let consumerDir = prepareOutputDir "rp-q021-consumer"
            try
                let producerDll =
                    buildPackage producerDir "Lyric.Q021Producer" """
package Lyric.Q021Producer

pub type Score = Int derives Compare, Hash, Equals

func main(): Unit { () }
"""

                // Stage the producer so the consumer can import it.
                File.Copy(
                    producerDll,
                    Path.Combine(consumerDir, "Lyric.Q021Producer.dll"),
                    overwrite = true)
                let consumerDll = Path.Combine(consumerDir, "rp-q021-consumer.dll")
                let req : EmitRequest =
                    { Source =
                        """
package Q021Consumer

import Lyric.Q021Producer

func minScore[T](a: T, b: T): T where T: Compare {
  if a < b { a } else { b }
}

func main(): Unit {
  val s1 = Score.from(10)
  val s2 = Score.from(30)
  val m = minScore(s1, s2)
  println(m.value)
}
"""
                      AssemblyName       = "rp-q021-consumer"
                      OutputPath         = consumerDll
                      RestoredPackages   =
                        [ { Name    = "Lyric.Q021Producer"
                            Version = "0.1.0"
                            DllPath = producerDll } ]
                      NugetAssemblyPaths = []
                      ExternShimRoot     = None
                      Target             = Dotnet
                      ActiveFeatures     = Set.empty
                      DeclaredFeatures   = Set.empty }
                let result = emit req
                let errs =
                    result.Diagnostics
                    |> List.filter (fun d -> d.Severity = Lyric.Lexer.DiagError)
                Expect.isEmpty errs
                    (sprintf "Q021-4 Path 1.5 consumer had errors (ImportedDistinct path): %A" errs)
                let stdout, stderr, exitCode = runDll consumerDll
                Expect.equal exitCode 0
                    (sprintf "Q021-4 consumer exit %d (stderr=%s)" exitCode stderr)
                Expect.equal (stdout.TrimEnd()) "10"
                    "minScore(10, 30) returns the smaller score"
            finally
                try Directory.Delete(producerDir, recursive = true) with _ -> ()
                try Directory.Delete(consumerDir, recursive = true) with _ -> ()

        // F11 / Q022-1 pubUseDecls regression.
        // A `pub use` declaration in package B must forward its source's
        // pub items into the contract metadata for B so that downstream
        // consumers can reason about re-exported API surfaces.
        // Known bug: buildContract is called with an empty importedSources map
        // in the emitter (Emitter.fs emit path), so pubUseDecls always returns []
        // and no re-exported items appear in the contract JSON.
        // Pending until the emitter passes the live importedSources into buildContract.
        ptestCase "Q022-1 pubUseDecls: pub-use re-exports appear in contract resource" <| fun () ->
            // Build the source package whose items will be re-exported.
            let sourceDir   = guidDir "lyric-rp-q022-source"
            let reexportDir = guidDir "lyric-rp-q022-reexport"
            try
                let sourceDll =
                    buildPackage sourceDir "Lyric.Q022Source" """
package Lyric.Q022Source

pub func sourceFunc(x: in Int): Int = x + 1

func main(): Unit { () }
"""

                // Build the re-exporting package (uses pub use).
                let reexportDll =
                    let dll = Path.Combine(reexportDir, "Lyric.Q022Reexport.dll")
                    let req : EmitRequest =
                        { Source =
                            """
package Lyric.Q022Reexport

pub use Lyric.Q022Source.{sourceFunc}

func main(): Unit { () }
"""
                          AssemblyName       = "Lyric.Q022Reexport"
                          OutputPath         = dll
                          RestoredPackages   =
                            [ { Name    = "Lyric.Q022Source"
                                Version = "0.1.0"
                                DllPath = sourceDll } ]
                          NugetAssemblyPaths = []
                          ExternShimRoot     = None
                          Target             = Dotnet
                          ActiveFeatures     = Set.empty
                          DeclaredFeatures   = Set.empty }
                    let r = emit req
                    let errs =
                        r.Diagnostics
                        |> List.filter (fun d -> d.Severity = Lyric.Lexer.DiagError)
                    if not (List.isEmpty errs) then
                        failwithf "reexport build failed: %A" errs
                    dll

                // Check that the embedded contract for the re-exporting package
                // includes the cherry-picked sourceFunc.
                match ContractMeta.readFromAssembly reexportDll with
                | None ->
                    failtest "Lyric.Q022Reexport has no embedded Lyric.Contract resource"
                | Some json ->
                    Expect.stringContains json "sourceFunc"
                        "pubUseDecls: re-exported sourceFunc must appear in contract"
            finally
                try Directory.Delete(sourceDir,   recursive = true) with _ -> ()
                try Directory.Delete(reexportDir, recursive = true) with _ -> ()
    ]
