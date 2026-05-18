module Lyric.Cli.Tests.ProjectBuildTests

open System
open System.Diagnostics
open System.IO
open Expecto

/// Locate the `lyric` CLI assembly that lives next to this test
/// binary.  `Lyric.Cli` ships as `lyric.dll` (per its `.fsproj`
/// AssemblyName) and is copied into the test project's output dir
/// by the project reference.
let private cliDll () : string =
    Path.Combine(AppContext.BaseDirectory, "lyric.dll")

/// Run `lyric` with the given args, returning (stdout, stderr, exit).
/// Inherits the current `dotnet` host so the runtime resolution
/// works the same way it does for end users.
let private runCli (args: string list) : string * string * int =
    let psi = ProcessStartInfo()
    psi.FileName <- "dotnet"
    psi.Arguments <- String.concat " " ("exec" :: cliDll () :: args)
    psi.UseShellExecute <- false
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.CreateNoWindow <- true
    match Option.ofObj (Process.Start(psi)) with
    | None -> failwith "Process.Start returned null"
    | Some proc ->
        use proc = proc
        let stdout = proc.StandardOutput.ReadToEnd()
        let stderr = proc.StandardError.ReadToEnd()
        proc.WaitForExit()
        stdout, stderr, proc.ExitCode

/// Run an emitted DLL via `dotnet exec` and return (stdout, stderr,
/// exit).  The DLL's runtimeconfig.json must already be in place.
let private runDll (dll: string) : string * string * int =
    let psi = ProcessStartInfo()
    psi.FileName <- "dotnet"
    psi.Arguments <- "exec " + dll
    psi.UseShellExecute <- false
    psi.RedirectStandardOutput <- true
    psi.RedirectStandardError  <- true
    psi.CreateNoWindow <- true
    match Option.ofObj (Process.Start(psi)) with
    | None -> failwith "Process.Start returned null"
    | Some proc ->
        use proc = proc
        let stdout = proc.StandardOutput.ReadToEnd()
        let stderr = proc.StandardError.ReadToEnd()
        proc.WaitForExit()
        stdout, stderr, proc.ExitCode

let private freshProjectDir () : string =
    let dir = Path.Combine(Path.GetTempPath(),
                            "lyric-projbuild-test-" + Guid.NewGuid().ToString("N"))
    Directory.CreateDirectory dir |> ignore
    dir

let private coreSrc =
    "package MyApp.Core\n" +
    "\n" +
    "@stable(since=\"0.1\")\n" +
    "pub func double(x: in Int): Int { x + x }\n"

let private appSrc =
    "package MyApp.App\n" +
    "\n" +
    "import MyApp.Core\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(toString(double(7)))\n" +
    "}\n"

let private manifestToml =
    "[package]\n" +
    "name = \"MyApp\"\n" +
    "version = \"0.1.0\"\n" +
    "\n" +
    "[project]\n" +
    "name = \"MyApp\"\n" +
    "output = \"single\"\n" +
    "output_assembly = \"MyApp.dll\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"MyApp.Core\" = \"src/core\"\n" +
    "\"MyApp.App\"  = \"src/app\"\n"

let private emptyProjectToml =
    "[package]\n" +
    "name = \"Empty\"\n" +
    "version = \"0.1.0\"\n" +
    "\n" +
    "[project]\n" +
    "name = \"Empty\"\n" +
    "output = \"single\"\n"

/// Stage 2c.2.iv: `lyric build --manifest <lyric.toml>` (no
/// positional source) reads `[project] output = "single"` and
/// dispatches to the project-as-DLL emitter.  The resulting bundle
/// carries one `Lyric.Contract.<Pkg>` resource per package and
/// runs as a single executable.
let tests =
    testList "Lyric.Cli.ProjectBuild" [

        testCase "lyric build --manifest bundles a multi-package project" <| fun () ->
            let root = freshProjectDir ()
            let coreDir = Path.Combine(root, "src", "core")
            let appDir  = Path.Combine(root, "src", "app")
            Directory.CreateDirectory coreDir |> ignore
            Directory.CreateDirectory appDir  |> ignore
            File.WriteAllText(Path.Combine(coreDir, "core.l"), coreSrc)
            File.WriteAllText(Path.Combine(appDir,  "app.l"),  appSrc)
            File.WriteAllText(Path.Combine(root, "lyric.toml"), manifestToml)

            let manifestPath = Path.Combine(root, "lyric.toml")
            let stdout, stderr, exitCode =
                runCli [ "build"; "--manifest"; manifestPath ]
            Expect.equal exitCode 0
                (sprintf "lyric build exited %d (stderr=%s, stdout=%s)"
                         exitCode stderr stdout)

            let bundle = Path.Combine(root, "bin", "MyApp.dll")
            Expect.isTrue (File.Exists bundle)
                (sprintf "bundle DLL produced at %s" bundle)
            let cfg = Path.ChangeExtension(bundle, ".runtimeconfig.json")
            Expect.isTrue (File.Exists cfg)
                "runtimeconfig.json sits next to the bundle"

            let contracts =
                Lyric.Emitter.ContractMeta.readAllContractsFromAssembly bundle
                |> List.map fst
                |> List.sort
            Expect.equal contracts [ "MyApp.App"; "MyApp.Core" ]
                "bundle carries one Lyric.Contract.<Pkg> per package"

            let legacyContract =
                Lyric.Emitter.ContractMeta.readFromAssembly bundle
            Expect.isNone legacyContract
                "no legacy `Lyric.Contract` resource on a bundled DLL"

            let runOut, runErr, runExit = runDll bundle
            Expect.equal runExit 0
                (sprintf "bundle run exited %d (stderr=%s)" runExit runErr)
            Expect.equal (runOut.Trim()) "14"
                "main printed double(7) from MyApp.Core"

        testCase "lyric build --manifest reports empty [project.packages]" <| fun () ->
            let root = freshProjectDir ()
            File.WriteAllText(
                Path.Combine(root, "lyric.toml"), emptyProjectToml)
            let manifestPath = Path.Combine(root, "lyric.toml")
            let _, stderr, exitCode =
                runCli [ "build"; "--manifest"; manifestPath ]
            Expect.notEqual exitCode 0
                "empty project rejected"
            Expect.stringContains stderr "[project.packages] is empty"
                "stderr explains the missing package list"
    ]
